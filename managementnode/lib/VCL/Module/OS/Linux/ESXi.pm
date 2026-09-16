#!/usr/bin/perl -w
###############################################################################
# $Id$
###############################################################################
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
###############################################################################

=head1 NAME

VCL::Module::OS::Linux::ESXi.pm

=head1 DESCRIPTION

 VCL OS module for VMware ESXi guests (nested ESXi) and kickstart-installed
 ESXi hosts that use this module.

 This class subclasses Linux.pm only for shared SSH/file helpers. It does
 B<not> call Linux.pm SUPER methods for capture, network, user, firewall,
 service, or hostname paths. Those Linux methods emit GNU/Linux userland
 (useradd, passwd --stdin, ifconfig/ifcfg, chkconfig, iptables, rdate,
 /etc/sysconfig/network, ext_sshd). ESXi is BusyBox plus esxcli / esxcfg-*
 / vim-cmd.

=head2 Linux vs ESXi image lifecycle

 Orchestrator (image.pm / new.pm / reserved.pm / reclaim.pm / VMware.pm):

   load          : provisioner->load() then OS post_load
   reserve       : OS reserve (accounts + public IP)
   grant_access  : user clicked Connect (firewall + optional nested-lab NAS)
   capture       : OS post_reservation -> provisioner.capture()
                   (OS pre_capture, then VM snapshot/clone/export)
                   -> OS post_capture
   checkpoint    : after capture, OS post_load then OS reserve
   reclaim       : OS post_reservation; OS sanitize (reload if sanitize fails)

 Linux step                         ESXi equivalent
 ----------------------------------------------------------------
 OS::pre_capture (SSH, currentimage, stage scripts)
                                    Same (called as VCL::Module::OS, not Linux)
 generate_exclude_list_sample       Skip: Linux /root/.vclcontrol path
 logoff_user (pkill -u)             Skip: no regular login sessions to kill
 unmount_nfs + fstab                esxcli storage nfs remove / esxcfg-nas -d
 delete_user_accounts (userdel)     esxcli system account remove
 set_password root (passwd --stdin) esxcli system account set
 disable firstboot service          Skip: no SysV firstboot
 configure_default_sshd / rc.local  Skip: single TSM-SSH, no rc.local tooling
 firewall process_pre_capture       esxcli network firewall: keep sshServer
 clean_known_files                  Skip: Linux log/udev/ifcfg paths
 enable_dhcp + ifcfg-* / route-*    FollowHardwareMac + Instant Clone-style
                                    vmk0 recreate + DHCP (DHCP-only leaves
                                    baked MAC/IP in esx.conf)
 /etc/sysconfig/network HOSTNAME    esxcli system hostname (cleared to image default)
 shutdown -h now                    esxcli system shutdown poweroff
 provisioner capture                Unchanged: VMware.pm copies/renames vmdk
 OS::post_capture stage scripts     Same (management node)

 post_load:
   guestOps vmk0/SSH bootstrap      Nested ESXi only: GuestOperationsManager
                                    (no guest SSH) to rewrite vmk0 to the VCL
                                    computer IP and install MN authorized_keys
   wait SSH                         Same
   activate_interfaces (ip/ifcfg)   Verify VMkernel NICs via esxcli/esxcfg-vmknic
   Linux firewall post_load         Skip iptables; ensure sshServer enabled
   update_public_ip_address         Same OS.pm helper (uses ESXi NIC parse)
   configure_ext_sshd               Skip: ESXi has one SSH daemon
   configure_rc_local               Skip
   currentimage.txt                 Same OS.pm helper
   synchronize_time (rdate/ntpd)    esxcli system ntp set
   set_password root                esxcli system account set
   clear_private_keys               Skip: ESXi authorized_keys persist path differs
   update_public_hostname           esxcli system hostname set
   vcl_post_load scripts            Run if present under /scratch or /usr/local/vcl
   OS::post_load stage scripts      Same

 reserve:
   groupadd vcl                     Skip: no GNU groupadd
   configure_ext_sshd               Skip
   OS::reserve (IP + add_user)      Same; create_user uses ESXi account APIs
   mount_nfs_shares (mount -t nfs)  esxcli storage nfs add / esxcfg-nas -a

 grant_access:
   Linux firewall process_reserved  esxcli network firewall ruleset enable
   process_connect_methods          Same (SSH + optional vSphere ports)
   (legacy student lab)             Optional NAS + vim-cmd solo/registervm
                                    if ESXI_STORAGE_* is set in vcld.conf

 sanitize:
   Linux: firewall + userdel + stop ext_sshd
   ESXi: if computer was inuse, return 0 so reclaim reloads (guest hypervisor
         may have been changed). If user never connected, delete VCL accounts
         and reuse the image.

 Nested hypervisor VMX extras (vhv.enable, monitor.virtual_*) are already
 added by VMware.pm when the host reports nestedHVSupported. This module
 does not invent a new provisioning path.

=cut

###############################################################################
package VCL::Module::OS::Linux::ESXi;

# Specify the lib path using FindBin
use FindBin;
use lib "$FindBin::Bin/../../../..";

# Configure inheritance
use base qw(VCL::Module::OS::Linux);

# Specify the version of this module
our $VERSION = '2.5.1';

# Specify the version of Perl to use
use 5.008000;

use strict;
use warnings;
use diagnostics;

use VCL::utils;

###############################################################################

=head1 CLASS VARIABLES

=cut

=head2 $SOURCE_CONFIGURATION_DIRECTORY

 Data type   : String
 Description : Stage-script directory for this OS module. tools/ESXi already
               exists in-tree (empty Script stage folders). Linux tools/ are
               not used for ESXi guest prep.

=cut

our $SOURCE_CONFIGURATION_DIRECTORY = "$TOOLS/ESXi";

=head2 $NODE_CONFIGURATION_DIRECTORY

 Data type   : String
 Description : Persistent-ish location on ESXi. /root/VCL is a Linux path;
               ESXi root's home is often / and /scratch is the supported
               scratch partition.

=cut

our $NODE_CONFIGURATION_DIRECTORY = '/scratch/VCL';

# Accounts that must never be deleted by VCL sanitize/capture
my @ESXI_RESERVED_ACCOUNTS = qw(root dcui vpxuser nobody);

###############################################################################

=head1 OBJECT METHODS

=cut

#//////////////////////////////////////////////////////////////////////////////

=head2 get_node_configuration_directory

 Parameters  : none
 Returns     : string
 Description : Returns /scratch/VCL instead of Linux /root/VCL.

=cut

sub get_node_configuration_directory {
	return $NODE_CONFIGURATION_DIRECTORY;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 firewall

 Parameters  : none
 Returns     : dummy Linux::firewall object
 Description : Linux.pm::firewall() probes iptables/firewalld/ufw. ESXi uses
               esxcli network firewall. Return the generic no-op firewall
               class so leftover can('process_*') checks skip Linux chains.

=cut

sub firewall {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	return $self->{firewall} if $self->{firewall};
	
	notify($ERRORS{'DEBUG'}, 0, "ESXi uses esxcli network firewall, not a Linux firewall module");
	$self->{firewall} = bless {}, 'VCL::Module::OS::Linux::firewall';
	return $self->{firewall};
}

#//////////////////////////////////////////////////////////////////////////////

=head2 get_init_modules

 Parameters  : none
 Returns     : empty list
 Description : Skip SysV/systemd/Upstart probing. ESXi has no Linux init
               daemon VCL can drive; SSH is TSM-SSH via vim-cmd hostsvc.

=cut

sub get_init_modules {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	if ($self->{init_modules}) {
		return @{$self->{init_modules}};
	}
	
	notify($ERRORS{'DEBUG'}, 0, "skipping Linux init daemon probe on ESXi");
	$self->{init_modules} = [];
	return ();
}

#//////////////////////////////////////////////////////////////////////////////

=head2 pre_capture

 Parameters  : $args (hash ref, optional end_state)
 Returns     : boolean
 Description : Prepares an ESXi guest for image capture. Calls OS.pm
               pre_capture (not Linux.pm), then ESXi-specific cleanup:
               NFS datastores, VCL accounts, root password, SSH, generalize
               the management VMkernel (FollowHardwareMac + vmk0 recreate +
               DHCP), power off.

               DHCP alone is not enough: esxcli ipv4 --type=dhcp leaves the
               vmk0 MAC and often the last address in /etc/vmware/esx.conf,
               so clones boot with the capture host's identity. Load-time
               GuestOps (_bootstrap_nested_management_network) still rewrites
               vmk0 for older images; this path makes *new* captures cleaner.

=cut

sub pre_capture {
	my $self = shift;
	my $args = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	if (defined $args->{end_state}) {
		$self->{end_state} = $args->{end_state};
	}
	else {
		$self->{end_state} = 'off';
	}
	
	my $computer_node_name = $self->data->get_computer_node_name();
	
	# Common capture prep only — do not call Linux.pm::pre_capture
	if (!VCL::Module::OS::pre_capture($self, $args)) {
		notify($ERRORS{'WARNING'}, 0, "failed to execute parent OS pre_capture() subroutine");
		return;
	}
	
	notify($ERRORS{'OK'}, 0, "beginning ESXi image capture preparation tasks");
	
	# Skip generate_exclude_list_sample: Linux /root/.vclcontrol
	# Skip logoff_user: pkill is not useful on ESXi
	
	$self->unmount_nfs_shares();
	$self->_unmount_esxi_nas_datastores();
	
	if ($self->delete_user_accounts()) {
		notify($ERRORS{'OK'}, 0, "deleted VCL user accounts from $computer_node_name");
	}
	
	# Known troubleshooting password, same intent as Linux.pm pre_capture
	$self->set_password("root", $WINDOWS_ROOT_PASSWORD) if $WINDOWS_ROOT_PASSWORD;
	
	# Skip firstboot / configure_default_sshd / configure_rc_local / Linux firewall / clean_known_files
	$self->_ensure_ssh_enabled();
	$self->_enable_esxi_ruleset('sshServer', 'all');
	
	# Capture-time identity generalize (SSH is still up).
	# Order matters:
	#   1. NFS / accounts / root password / TSM-SSH  — need a working vmk0
	#   2. FollowHardwareMac + UUID scrub + lease cleanup + auto-backup — SSH stays
	#   3. Detached Instant Clone-style vmk0 recreate + DHCP — SSH will drop
	#   4. enable_dhcp verify if SSH returns (same DHCP IP)
	#   5. shutdown() — esxcli if SSH is up, else provisioner power_off
	# Do not call _bootstrap_nested_management_network here: that path is
	# GuestOps (no guest SSH) and assigns the *reservation* static IP at load.
	my $private_interface_name = $self->get_private_interface_name();
	my $public_interface_name = $self->get_public_interface_name();
	my $management_interface_name = ($private_interface_name && $private_interface_name =~ /^vmk\d+$/) ? $private_interface_name : 'vmk0';
	
	my $vmk_recreated = $self->_generalize_management_vmkernel($management_interface_name);
	
	if ($self->wait_for_ssh(0)) {
		if ($private_interface_name && !$self->enable_dhcp($private_interface_name)) {
			if ($vmk_recreated) {
				notify($ERRORS{'WARNING'}, 0, "failed to verify DHCP on the private VMkernel interface after generalize; the detached guest script should already have set DHCP");
			}
			else {
				notify($ERRORS{'WARNING'}, 0, "failed to enable DHCP on the private VMkernel interface");
				return;
			}
		}
		if ($public_interface_name && $public_interface_name ne ($private_interface_name || '') && !$self->enable_dhcp($public_interface_name)) {
			if ($vmk_recreated) {
				notify($ERRORS{'WARNING'}, 0, "failed to verify DHCP on the public VMkernel interface after generalize; the detached guest script should already have set DHCP");
			}
			else {
				notify($ERRORS{'WARNING'}, 0, "failed to enable DHCP on the public VMkernel interface");
				return;
			}
		}
	}
	elsif ($vmk_recreated) {
		notify($ERRORS{'DEBUG'}, 0, "SSH not available after vmk0 recreate on $computer_node_name (expected if DHCP issued a different address); DHCP was set on-guest, proceeding to shutdown");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "SSH not available on $computer_node_name and management VMkernel was not recreated; cannot enable DHCP");
		return;
	}
	
	if ($self->{end_state} =~ /off/i) {
		notify($ERRORS{'DEBUG'}, 0, "shutting down $computer_node_name, provisioning module specified end state: $self->{end_state}");
		if (!$self->shutdown()) {
			notify($ERRORS{'WARNING'}, 0, "failed to shut down $computer_node_name");
			return;
		}
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "$computer_node_name not shut down, provisioning module specified end state: $self->{end_state}");
	}
	
	notify($ERRORS{'OK'}, 0, "ESXi pre-capture steps complete");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 post_load

 Parameters  : none
 Returns     : boolean
 Description : ESXi post-load. Does not call Linux.pm::post_load (ifcfg,
               ext_sshd, rdate, /etc/sysconfig). For nested ESXi on a VMware
               vmhost, reconfigures vmk0 / root authorized_keys via guest
               operations (no guest SSH) after powerOn, then waits for SSH,
               writes currentimage.txt, confirms VMkernel NICs, updates public
               IP, syncs time, sets root password, hostname, then OS.pm
               post_load.

=cut

sub post_load {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $image_name = $self->data->get_image_name();
	my $computer_node_name = $self->data->get_computer_node_name();
	
	notify($ERRORS{'OK'}, 0, "beginning ESXi post_load tasks, image: $image_name, computer: $computer_node_name");
	
	# Nested ESXi golden images persist vmk0 IP/MAC in esx.conf. New captures
	# generalize this in pre_capture (FollowHardwareMac + vmk recreate + DHCP).
	# This GuestOps rewrite still covers older images and any clone whose
	# identity drifted, and it runs before wait_for_ssh (chicken-and-egg).
	if (!$self->_bootstrap_nested_management_network()) {
		notify($ERRORS{'WARNING'}, 0, "nested ESXi management-network bootstrap did not complete; still attempting SSH to $computer_node_name");
	}
	
	if (!$self->wait_for_response(5, 600, 5)) {
		notify($ERRORS{'WARNING'}, 0, "$computer_node_name never responded to SSH");
		return;
	}
	
	if (!$self->create_currentimage_txt()) {
		notify($ERRORS{'WARNING'}, 0, "failed to create currentimage.txt on $computer_node_name");
		return;
	}
	
	$self->_ensure_ssh_enabled();
	$self->activate_interfaces();
	$self->_enable_esxi_ruleset('sshServer', 'all');
	
	if (!$self->update_public_ip_address()) {
		notify($ERRORS{'WARNING'}, 0, "failed to update public IP address");
		return;
	}
	
	# Skip configure_ext_sshd and configure_rc_local
	
	if (!$self->synchronize_time()) {
		notify($ERRORS{'WARNING'}, 0, "unable to synchronize date and time on $computer_node_name");
	}
	
	if (!$self->set_password("root")) {
		notify($ERRORS{'OK'}, 0, "failed to set root password on $computer_node_name");
	}
	
	# Skip clear_private_keys: Linux /root/.ssh identity cleanup
	
	my $set_hostname = $self->data->get_imagemeta_sethostname(0);
	if (defined($set_hostname) && $set_hostname =~ /0/) {
		notify($ERRORS{'DEBUG'}, 0, "not setting computer hostname, imagemeta.sethostname = $set_hostname");
	}
	else {
		$self->update_public_hostname();
	}
	
	my @post_load_script_paths = ('/usr/local/vcl/vcl_post_load', '/scratch/VCL/vcl_post_load');
	foreach my $script_path (@post_load_script_paths) {
		if ($self->file_exists($script_path)) {
			my $result = $self->run_script($script_path, '1', '300', '1');
			if (!defined($result)) {
				notify($ERRORS{'WARNING'}, 0, "error occurred running $script_path");
			}
			else {
				notify($ERRORS{'DEBUG'}, 0, "ran $script_path") if $result;
			}
		}
	}
	
	return VCL::Module::OS::post_load($self);
}

#//////////////////////////////////////////////////////////////////////////////

=head2 reserve

 Parameters  : none
 Returns     : boolean
 Description : Reserves the ESXi guest. Skips Linux groupadd/ext_sshd. Calls
               OS.pm::reserve for public IP + add_user_accounts.

=cut

sub reserve {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}
	
	notify($ERRORS{'OK'}, 0, "beginning ESXi reserve tasks");
	
	# ESXi nested: esperar SSH del guest tras el load (2-3 min de boot)
	if (!$self->wait_for_ssh(600, 15)) {
		notify($ERRORS{'WARNING'}, 0, "ESXi guest did not respond to SSH after 10 minutes");
		return;
	}

	# esperar a que hostd responda (esxcli da 503 mientras hostd arranca)
	for my $attempt (1 .. 24) {
		my ($exit_status, $output) = $self->execute('esxcli network ip interface ipv4 get', 0);
		last if defined($output) && $exit_status eq '0';
		notify($ERRORS{'DEBUG'}, 0, "hostd not ready yet (esxcli exit $exit_status), attempt $attempt/24");
		sleep 10;
	}
	
	# Skip add_vcl_usergroup and configure_ext_sshd
	
	if (!VCL::Module::OS::reserve($self)) {
		return;
	}
	
	$self->mount_nfs_shares();
	
	notify($ERRORS{'OK'}, 0, "ESXi reserve tasks complete");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 grant_access

 Parameters  : none
 Returns     : boolean
 Description : Called when the user clicks Connect. Opens ESXi firewall
               rulesets for connect methods. Optionally mounts per-user NFS
               storage and registers VMX files (nested student lab extras
               from the original module, only if ESXI_STORAGE_* is set).

=cut

sub grant_access {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}
	
	my $computer_short_name = $self->data->get_computer_short_name();
	notify($ERRORS{'OK'}, 0, "$computer_short_name: processing with ESXi.pm::grant_access()");
	
	# Enable typical ESXi management rulesets before connect-method loop
	for my $ruleset (qw(sshServer webAccess vSphereClient httpsHostAgent)) {
		$self->_enable_esxi_ruleset($ruleset);
	}
	
	if ($self->process_connect_methods("", 1)) {
		notify($ERRORS{'DEBUG'}, 0, "granted access to $computer_short_name by processing the connection methods");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to grant access to $computer_short_name by processing the connection methods");
		return;
	}
	
	# Optional nested-lab NAS + registervm (original ESXi.pm extras)
	if (!$self->_configure_nested_lab_storage()) {
		notify($ERRORS{'WARNING'}, 0, "nested-lab storage configuration failed on $computer_short_name");
		# Do not fail the reservation; user can still SSH / use the host UI
	}
	
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 post_reserve

 Parameters  : none
 Returns     : boolean
 Description : Skip Linux vcl_post_reserve / userdata Linux paths. Run OS.pm
               stage scripts only.

=cut

sub post_reserve {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}
	
	return VCL::Module::OS::post_reserve($self);
}

#//////////////////////////////////////////////////////////////////////////////

=head2 post_reservation

 Parameters  : none
 Returns     : boolean
 Description : Skip Linux /usr/local/vcl/vcl_post_reservation unless the file
               exists. Always run OS.pm stage scripts.

=cut

sub post_reservation {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}
	
	my $script_path = '/usr/local/vcl/vcl_post_reservation';
	if ($self->file_exists($script_path)) {
		$self->run_script($script_path, '1', '300', '1');
	}
	
	return VCL::Module::OS::post_reservation($self);
}

#//////////////////////////////////////////////////////////////////////////////

=head2 sanitize

 Parameters  : none
 Returns     : boolean
 Description : If the computer reached inuse, the guest hypervisor may have
               been changed — return 0 so reclaim reloads. If the user never
               connected, delete VCL accounts and reuse the image.

=cut

sub sanitize {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $computer_short_name = $self->data->get_computer_short_name();
	my $computer_state_name = $self->data->get_computer_state_name();
	
	if ($computer_state_name =~ /^(inuse)$/) {
		notify($ERRORS{'OK'}, 0, "$computer_short_name : user connected; ESXi guest must be reloaded");
		return 0;
	}
	
	notify($ERRORS{'OK'}, 0, "$computer_short_name : user never connected, sanitizing VCL accounts for reuse");
	
	$self->unmount_nfs_shares();
	$self->_unmount_esxi_nas_datastores();
	
	if (!$self->delete_user_accounts()) {
		notify($ERRORS{'WARNING'}, 0, "failed to delete VCL user accounts on $computer_short_name, computer will be reloaded");
		return 0;
	}
	
	notify($ERRORS{'OK'}, 0, "$computer_short_name has been sanitized");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 create_user

 Parameters  : $user_parameters hash ref
 Returns     : boolean
 Description : Creates an ESXi local account via esxcli system account
               (ESXi 6+) or vim-cmd / useradd fallback. Grants Admin via
               esxcli system permission or vim-cmd vimsvc/auth.

=cut

sub create_user {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $computer_node_name = $self->data->get_computer_node_name();
	my $user_parameters = shift;
	if (!$user_parameters || !ref($user_parameters) || ref($user_parameters) ne 'HASH') {
		notify($ERRORS{'WARNING'}, 0, "unable to create user, user parameters argument was not provided");
		return;
	}
	
	my $username = $user_parameters->{username};
	my $root_access = $user_parameters->{root_access};
	my $password = $user_parameters->{password};
	if (!defined($username) || !defined($root_access)) {
		notify($ERRORS{'WARNING'}, 0, "failed to create user on $computer_node_name, username/root_access missing:\n" . format_data($user_parameters));
		return;
	}
	
	if (!$self->user_exists($username)) {
		notify($ERRORS{'DEBUG'}, 0, "creating ESXi user on $computer_node_name: $username");
		if (!$self->_add_esxi_account($username, $password)) {
			notify($ERRORS{'WARNING'}, 0, "failed to add ESXi account $username on $computer_node_name");
			return;
		}
	}
	elsif ($password) {
		$self->set_password($username, $password) || return;
	}
	
	if ($root_access) {
		if (!$self->grant_administrative_access($username)) {
			notify($ERRORS{'WARNING'}, 0, "failed to grant Admin role to $username on $computer_node_name");
			return;
		}
	}
	else {
		$self->revoke_administrative_access($username);
	}
	
	# Skip grant_connect_method_access Linux ext_sshd /home/.ssh path
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 delete_user

 Parameters  : $username
 Returns     : boolean
 Description : Removes an ESXi local account. Never deletes reserved
               accounts (root, dcui, vpxuser, nobody).

=cut

sub delete_user {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}
	
	my $username = shift;
	$username = $self->data->get_user_login_id() if (!$username);
	if (!$username) {
		notify($ERRORS{'WARNING'}, 0, "user could not be determined");
		return;
	}
	
	my $computer_node_name = $self->data->get_computer_node_name();
	
	if (grep { $_ eq $username } @ESXI_RESERVED_ACCOUNTS) {
		notify($ERRORS{'DEBUG'}, 0, "not deleting reserved ESXi account: $username");
		return 1;
	}
	
	if (!$self->user_exists($username)) {
		notify($ERRORS{'DEBUG'}, 0, "user NOT deleted from $computer_node_name because it does not exist: $username");
		$self->revoke_administrative_access($username);
		return 1;
	}
	
	$self->revoke_administrative_access($username);
	
	if ($self->_supports_esxcli_accounts()) {
		my $quoted = $self->_shell_quote($username);
		my ($exit_status, $output) = $self->execute("esxcli system account remove -i $quoted");
		if (!defined($output)) {
			notify($ERRORS{'WARNING'}, 0, "failed to execute esxcli system account remove for $username");
			return;
		}
		elsif ($exit_status && $exit_status ne '0' && !grep(/does not exist|not found/i, @$output)) {
			notify($ERRORS{'WARNING'}, 0, "failed to remove ESXi account $username, exit status: $exit_status, output:\n" . join("\n", @$output));
			return;
		}
		notify($ERRORS{'OK'}, 0, "deleted ESXi account $username from $computer_node_name");
		return 1;
	}
	
	# Legacy ESXi 4.x BusyBox userdel
	my ($exit_status, $output) = $self->execute("userdel $username");
	if (!defined($output)) {
		notify($ERRORS{'WARNING'}, 0, "failed to execute userdel for $username");
		return;
	}
	notify($ERRORS{'OK'}, 0, "deleted user $username from $computer_node_name via userdel fallback");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 user_exists

 Parameters  : $username (optional)
 Returns     : boolean
 Description : Uses esxcli system account list, then id as fallback.

=cut

sub user_exists {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $computer_node_name = $self->data->get_computer_node_name();
	my $username = shift || $self->data->get_user_login_id();
	if (!$username) {
		notify($ERRORS{'WARNING'}, 0, "username could not be determined");
		return;
	}
	
	if ($self->_supports_esxcli_accounts()) {
		my ($exit_status, $output) = $self->execute("esxcli system account list");
		if (!defined($output)) {
			notify($ERRORS{'WARNING'}, 0, "failed to list ESXi accounts on $computer_node_name");
			return;
		}
		for my $line (@$output) {
			if ($line =~ /^\s*\Q$username\E\s/) {
				notify($ERRORS{'DEBUG'}, 0, "user exists on $computer_node_name: $username");
				return 1;
			}
		}
		notify($ERRORS{'DEBUG'}, 0, "user does not exist on $computer_node_name: $username");
		return 0;
	}
	
	my ($exit_status, $output) = $self->execute("id $username", 0);
	if (!defined($output)) {
		notify($ERRORS{'WARNING'}, 0, "failed to run id on $computer_node_name");
		return;
	}
	if (grep(/uid/, @$output)) {
		notify($ERRORS{'DEBUG'}, 0, "user exists on $computer_node_name: $username");
		return 1;
	}
	notify($ERRORS{'DEBUG'}, 0, "user does not exist on $computer_node_name: $username");
	return 0;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 set_password

 Parameters  : $username, $password (optional)
 Returns     : boolean
 Description : Sets an ESXi account password via esxcli system account set.
               Falls back to passwd on older images that still have it.

=cut

sub set_password {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}
	
	my $username = shift;
	my $password = shift;
	if (!$username) {
		notify($ERRORS{'WARNING'}, 0, "username argument was not provided");
		return;
	}
	if (!$password) {
		$password = getpw(15);
	}
	
	my $computer_node_name = $self->data->get_computer_node_name();
	my $quoted_user = $self->_shell_quote($username);
	my $quoted_pass = $self->_shell_quote($password);
	
	if ($self->_supports_esxcli_accounts()) {
		my $command = "esxcli system account set -i $quoted_user -p $quoted_pass -c $quoted_pass";
		my ($exit_status, $output) = $self->execute($command);
		if (!defined($output)) {
			notify($ERRORS{'WARNING'}, 0, "failed to run esxcli system account set for $username");
			return;
		}
		elsif ($exit_status && $exit_status ne '0') {
			notify($ERRORS{'WARNING'}, 0, "failed to change password for $username on $computer_node_name, exit status: $exit_status, output:\n" . join("\n", @$output));
			return;
		}
		notify($ERRORS{'OK'}, 0, "changed password for $username on $computer_node_name via esxcli system account set");
		return 1;
	}
	
	# Legacy: GNU passwd --stdin is not on modern ESXi; try chpasswd-style echo
	my $command = "echo $quoted_pass | passwd $quoted_user --stdin";
	my ($exit_status, $output) = $self->execute($command);
	if (!defined($output)) {
		notify($ERRORS{'WARNING'}, 0, "failed to run passwd fallback for $username");
		return;
	}
	elsif (grep(/(unknown user|warning|error|not found)/i, @$output) && !grep(/password updated|changed/i, @$output)) {
		notify($ERRORS{'WARNING'}, 0, "failed to change password for $username via passwd fallback, output:\n" . join("\n", @$output));
		return;
	}
	notify($ERRORS{'OK'}, 0, "changed password for $username on $computer_node_name via passwd fallback");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 grant_administrative_access

 Parameters  : $username
 Returns     : boolean
 Description : Assigns the ESXi Admin role. Replaces Linux sudoers.

=cut

sub grant_administrative_access {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $username = shift;
	if (!defined($username)) {
		notify($ERRORS{'WARNING'}, 0, "username argument was not supplied");
		return;
	}
	
	my $quoted = $self->_shell_quote($username);
	my ($exit_status, $output) = $self->execute("esxcli system permission set -i $quoted -r Admin");
	if (defined($output) && (!$exit_status || $exit_status eq '0' || grep(/already/i, @$output))) {
		notify($ERRORS{'DEBUG'}, 0, "granted ESXi Admin role to $username via esxcli system permission");
		return 1;
	}
	
	# vim-cmd: isGroup=false
	($exit_status, $output) = $self->execute("vim-cmd vimsvc/auth/entity_permission_add vim.Folder:ha-folder-root $quoted false Admin true");
	if (!defined($output)) {
		notify($ERRORS{'WARNING'}, 0, "failed to grant Admin role to $username");
		return;
	}
	notify($ERRORS{'DEBUG'}, 0, "granted ESXi Admin role to $username via vim-cmd vimsvc/auth");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 revoke_administrative_access

 Parameters  : $username
 Returns     : boolean
 Description : Removes the ESXi Admin role. Replaces Linux sudoers edit.

=cut

sub revoke_administrative_access {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $username = shift;
	if (!defined($username)) {
		notify($ERRORS{'WARNING'}, 0, "username argument was not supplied");
		return;
	}
	
	if (grep { $_ eq $username } @ESXI_RESERVED_ACCOUNTS) {
		return 1;
	}
	
	my $quoted = $self->_shell_quote($username);
	my ($exit_status, $output) = $self->execute("esxcli system permission unset -i $quoted");
	if (defined($output) && (!$exit_status || $exit_status eq '0' || grep(/not found|does not exist/i, @$output))) {
		return 1;
	}
	
	$self->execute("vim-cmd vimsvc/auth/entity_permission_remove vim.Folder:ha-folder-root $quoted false");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 add_vcl_usergroup

 Parameters  : none
 Returns     : 1
 Description : Skip. Linux groupadd vcl is not valid on ESXi.

=cut

sub add_vcl_usergroup {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	notify($ERRORS{'DEBUG'}, 0, "skipping Linux groupadd vcl on ESXi");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 grant_connect_method_access

 Parameters  : $user_parameters
 Returns     : boolean
 Description : Skip Linux ext_sshd AllowUsers and /home/.ssh. ESXi SSH
               authenticates local accounts created in create_user.

=cut

sub grant_connect_method_access {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	notify($ERRORS{'DEBUG'}, 0, "skipping Linux ext_sshd AllowUsers / home SSH keys on ESXi");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 logoff_user

 Parameters  : $username (optional)
 Returns     : boolean
 Description : Skip Linux pkill -u. ESXi has no regular multiuser sessions
               VCL needs to kill before capture.

=cut

sub logoff_user {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}
	notify($ERRORS{'DEBUG'}, 0, "skipping Linux pkill logoff on ESXi");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 user_logged_in

 Parameters  : $username (optional)
 Returns     : boolean
 Description : ESXi does not expose Linux 'users' logins. Return 0 so
               delete_user does not wait on pkill.

=cut

sub user_logged_in {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	return 0;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 get_logged_in_users

 Parameters  : none
 Returns     : empty list
 Description : Skip Linux 'users' command.

=cut

sub get_logged_in_users {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	return ();
}

#//////////////////////////////////////////////////////////////////////////////

=head2 get_network_configuration

 Parameters  : $no_cache (optional)
 Returns     : hash reference
 Description : Builds the OS.pm network hash from esxcli / esxcfg-vmknic
               instead of Linux ifconfig + route.

=cut

sub get_network_configuration {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $no_cache = shift || 0;
	if ($no_cache) {
		delete $self->{network_configuration};
	}
	elsif ($self->{network_configuration}) {
		return $self->{network_configuration};
	}
	
	my $network_configuration = {};
	
	# MAC / name from esxcli network ip interface list
	my ($list_exit, $list_output) = $self->execute("esxcli network ip interface list");
	if (defined($list_output) && @$list_output) {
		my $interface_name;
		for my $line (@$list_output) {
			if ($line =~ /^(vmk\d+)\s*$/) {
				$interface_name = $1;
				$network_configuration->{$interface_name}{name} = $interface_name;
			}
			elsif ($line =~ /^\s*Name:\s+(vmk\d+)/) {
				$interface_name = $1;
				$network_configuration->{$interface_name}{name} = $interface_name;
			}
			elsif ($interface_name && $line =~ /^\s*MAC Address:\s+([\w:]+)/i) {
				$network_configuration->{$interface_name}{physical_address} = lc($1);
			}
		}
	}
	
	# IPv4 from esxcli network ip interface ipv4 get
	my ($ipv4_exit, $ipv4_output) = $self->execute("esxcli network ip interface ipv4 get");
	if (defined($ipv4_output)) {
		for my $line (@$ipv4_output) {
			# Name  IPv4 Address  IPv4 Netmask  IPv4 Broadcast  Address Type  Gateway
			if ($line =~ /^(vmk\d+)\s+(\d+\.\d+\.\d+\.\d+)\s+(\d+\.\d+\.\d+\.\d+)\s+(\d+\.\d+\.\d+\.\d+)/) {
				my ($name, $ip, $mask, $bcast) = ($1, $2, $3, $4);
				$network_configuration->{$name}{name} = $name;
				$network_configuration->{$name}{ip_address}{$ip} = $mask;
				$network_configuration->{$name}{broadcast_address} = $bcast;
			}
		}
	}
	
	# Fallback: esxcfg-vmknic -l (ESXi 4.x / when esxcli parse failed)
	if (!keys %$network_configuration) {
		my ($vmk_exit, $vmk_output) = $self->execute("esxcfg-vmknic -l");
		if (defined($vmk_output)) {
			for my $line (@$vmk_output) {
				next unless $line =~ /^(vmk\d+)\s+/;
				my @fields = split(/\s+/, $line);
				my $name = $fields[0];
				$network_configuration->{$name}{name} = $name;
				for my $field (@fields) {
					if ($field =~ /^(\d+\.\d+\.\d+\.\d+)$/ && $field ne '0.0.0.0') {
						if (!$network_configuration->{$name}{ip_address}) {
							$network_configuration->{$name}{ip_address}{$field} = '255.255.255.0';
						}
						elsif (!$network_configuration->{$name}{broadcast_address} && $field =~ /\.255$/) {
							$network_configuration->{$name}{broadcast_address} = $field;
						}
						else {
							# netmask often follows IP
							my @ips = keys %{$network_configuration->{$name}{ip_address}};
							if (@ips && $network_configuration->{$name}{ip_address}{$ips[0]} eq '255.255.255.0' && $field =~ /^255\./) {
								$network_configuration->{$name}{ip_address}{$ips[0]} = $field;
							}
						}
					}
					elsif ($field =~ /^([0-9a-f:]{11,})$/i) {
						$network_configuration->{$name}{physical_address} = lc($field);
					}
				}
			}
		}
	}
	
	# Default gateway
	my ($route_exit, $route_output) = $self->execute("esxcli network ip route ipv4 list");
	if (defined($route_output)) {
		for my $line (@$route_output) {
			if ($line =~ /^default\s+\S+\s+(\d+\.\d+\.\d+\.\d+)\s+(vmk\d+)/) {
				$network_configuration->{$2}{default_gateway} = $1 if $network_configuration->{$2};
			}
		}
	}
	
	$self->{network_configuration} = $network_configuration;
	notify($ERRORS{'DEBUG'}, 0, "retrieved ESXi network configuration:\n" . format_data($self->{network_configuration}));
	return $self->{network_configuration};
}

#//////////////////////////////////////////////////////////////////////////////

=head2 get_public_ip_address

 Parameters  : none
 Returns     : IP address string
 Description : Prefers vmk1 (original module contract), then OS.pm public
               interface logic using the ESXi network hash.

=cut

sub get_public_ip_address {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $network_configuration = $self->get_network_configuration();
	if ($network_configuration && $network_configuration->{vmk1}{ip_address}) {
		my ($vmk1_ip) = keys %{$network_configuration->{vmk1}{ip_address}};
		if ($vmk1_ip && $vmk1_ip !~ /^(0\.0\.0\.0|169\.254)/) {
			notify($ERRORS{'DEBUG'}, 0, "using vmk1 as public IP address: $vmk1_ip");
			return $vmk1_ip;
		}
	}
	
	return VCL::Module::OS::get_public_ip_address($self, @_);
}

#//////////////////////////////////////////////////////////////////////////////

=head2 enable_dhcp

 Parameters  : $interface_name
 Returns     : boolean
 Description : esxcli network ip interface ipv4 set --type=dhcp. Replaces
               Linux ifcfg BOOTPROTO=dhcp.

=cut

sub enable_dhcp {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $interface_name = shift;
	if (!$interface_name) {
		notify($ERRORS{'WARNING'}, 0, "interface name argument was not supplied");
		return;
	}
	
	my $computer_name = $self->data->get_computer_node_name();
	my $command = "esxcli network ip interface ipv4 set --interface-name=$interface_name --type=dhcp";
	my ($exit_status, $output) = $self->execute($command);
	if (!defined($output)) {
		notify($ERRORS{'WARNING'}, 0, "failed to execute DHCP command on $computer_name: $command");
		return;
	}
	elsif ($exit_status && $exit_status ne '0') {
		# Fallback for older hosts
		my ($legacy_exit, $legacy_output) = $self->execute("esxcfg-vmknic -i DHCP $interface_name");
		if (!defined($legacy_output) || ($legacy_exit && $legacy_exit ne '0' && !grep(/already|dhcp/i, @$legacy_output))) {
			notify($ERRORS{'WARNING'}, 0, "failed to enable DHCP on $interface_name, command: $command, output:\n" . join("\n", @$output));
			return;
		}
	}
	
	delete $self->{network_configuration};
	notify($ERRORS{'OK'}, 0, "enabled DHCP on $interface_name on $computer_name via esxcli");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 set_static_public_address

 Parameters  : none
 Returns     : boolean
 Description : Assigns a static IPv4 address on the public VMkernel NIC via
               esxcli. Replaces Linux ifcfg + ifup.

=cut

sub set_static_public_address {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}
	
	my $computer_name = $self->data->get_computer_short_name();
	my $ip_configuration = $self->data->get_management_node_public_ip_configuration();
	my $public_ip_address = $self->data->get_computer_public_ip_address();
	my $subnet_mask = $self->data->get_management_node_public_subnet_mask();
	my @dns_servers = $self->data->get_management_node_public_dns_servers();
	
	my $server_request_fixed_ip = $self->data->get_server_request_fixed_ip();
	if ($server_request_fixed_ip) {
		$public_ip_address = $server_request_fixed_ip;
		$subnet_mask = $self->data->get_server_request_netmask();
		@dns_servers = $self->data->get_server_request_dns_servers();
	}
	
	if ($ip_configuration !~ /static/i && !$server_request_fixed_ip) {
		notify($ERRORS{'WARNING'}, 0, "management node IP configuration is $ip_configuration, static public IP address can only be set if the IP configuration is static or if a fixed IP was requested");
		return;
	}
	elsif (!$public_ip_address || !$subnet_mask) {
		notify($ERRORS{'WARNING'}, 0, "failed to retrieve public IP address or subnet mask to assign to $computer_name");
		return;
	}
	
	my $public_interface_name = $self->get_public_interface_name();
	if (!$public_interface_name) {
		notify($ERRORS{'WARNING'}, 0, "unable to set static public IP address, public interface name could not be determined");
		return;
	}
	
	my $current_public_ip_address = $self->get_public_ip_address(0, 1);
	if ($current_public_ip_address && $current_public_ip_address eq $public_ip_address) {
		notify($ERRORS{'DEBUG'}, 0, "static public IP address does not need to be set, $computer_name is already configured to use $current_public_ip_address");
	}
	else {
		if (_pingnode($public_ip_address)) {
			notify($ERRORS{'CRITICAL'}, 0, "ip_address $public_ip_address is pingable, can not assign to $computer_name");
			return;
		}
		
		my $command = "esxcli network ip interface ipv4 set --interface-name=$public_interface_name --type=static --ipv4=$public_ip_address --netmask=$subnet_mask";
		my ($exit_status, $output) = $self->execute($command);
		if (!defined($output) || ($exit_status && $exit_status ne '0')) {
			notify($ERRORS{'WARNING'}, 0, "failed to set static IPv4 on $public_interface_name, command: $command, output:\n" . (defined($output) ? join("\n", @$output) : '<undef>'));
			return;
		}
	}
	
	if (!$self->set_static_default_gateway()) {
		notify($ERRORS{'WARNING'}, 0, "failed to set static public IP address on $computer_name, default gateway could not be set");
		return;
	}
	
	if (@dns_servers && !$self->update_resolv_conf(@dns_servers)) {
		notify($ERRORS{'WARNING'}, 0, "failed to set static public IP address on $computer_name, DNS servers could not be configured");
		return;
	}
	
	delete $self->{network_configuration};
	notify($ERRORS{'OK'}, 0, "set static public IP address on $computer_name");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 set_static_default_gateway

 Parameters  : none
 Returns     : boolean
 Description : esxcli network ip route ipv4 add. Replaces route add / route-*
               files.

=cut

sub set_static_default_gateway {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}
	
	my $computer_name = $self->data->get_computer_short_name();
	my $default_gateway = $self->get_correct_default_gateway();
	if (!$default_gateway) {
		notify($ERRORS{'WARNING'}, 0, "unable to set static default gateway on $computer_name, correct default gateway IP address could not be determined");
		return;
	}
	
	my $current_default_gateway = $self->get_public_default_gateway();
	if ($current_default_gateway && $current_default_gateway eq $default_gateway) {
		notify($ERRORS{'OK'}, 0, "default gateway on $computer_name is already set to $current_default_gateway");
		return 1;
	}
	
	$self->delete_default_gateway();
	
	my $command = "esxcli network ip route ipv4 add --gateway=$default_gateway --network=default";
	my ($exit_status, $output) = $self->execute($command);
	if (!defined($output) || ($exit_status && $exit_status ne '0' && !grep(/already/i, @$output))) {
		notify($ERRORS{'WARNING'}, 0, "failed to set default gateway on $computer_name to $default_gateway, output:\n" . (defined($output) ? join("\n", @$output) : '<undef>'));
		return 0;
	}
	
	delete $self->{network_configuration};
	notify($ERRORS{'OK'}, 0, "set default gateway on $computer_name to $default_gateway via esxcli");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 delete_default_gateway

 Parameters  : none
 Returns     : boolean
 Description : Removes the IPv4 default route via esxcli.

=cut

sub delete_default_gateway {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}
	
	my $computer_name = $self->data->get_computer_short_name();
	my $current_default_gateway = $self->get_public_default_gateway();
	if (!$current_default_gateway) {
		notify($ERRORS{'DEBUG'}, 0, "default gateway not set on $computer_name");
		return 1;
	}
	
	my $command = "esxcli network ip route ipv4 remove --network=default --gateway=$current_default_gateway";
	my ($exit_status, $output) = $self->execute($command);
	if (!defined($output)) {
		notify($ERRORS{'WARNING'}, 0, "failed to execute command to delete default gateway on $computer_name");
		return;
	}
	
	delete $self->{network_configuration};
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 activate_interfaces

 Parameters  : none
 Returns     : boolean
 Description : Confirms VMkernel interfaces exist. Skip Linux ip link / ifcfg.

=cut

sub activate_interfaces {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}
	
	my $network_configuration = $self->get_network_configuration(1);
	if (!$network_configuration || !keys %$network_configuration) {
		notify($ERRORS{'WARNING'}, 0, "no VMkernel interfaces were found");
		return;
	}
	
	notify($ERRORS{'DEBUG'}, 0, "VMkernel interfaces present: " . join(', ', sort keys %$network_configuration));
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 update_public_hostname

 Parameters  : none
 Returns     : boolean
 Description : esxcli system hostname set. Replaces Linux hostname /
               /etc/sysconfig/network HOSTNAME.

=cut

sub update_public_hostname {
	my $self = shift;
	unless (ref($self) && $self->isa('VCL::Module')) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine can only be called as a VCL::Module module object method");
		return;
	}
	
	my $computer_node_name = $self->data->get_computer_node_name();
	
	my $public_hostname = shift;
	if (!$public_hostname) {
		my $public_ip_address = $self->get_public_ip_address();
		if (!$public_ip_address) {
			notify($ERRORS{'WARNING'}, 0, "unable to determine public IP address on $computer_node_name");
			return;
		}
		$public_hostname = ip_address_to_hostname($public_ip_address) || $computer_node_name;
	}
	
	my $quoted = $self->_shell_quote($public_hostname);
	my $hostname_command = ($public_hostname =~ /\./) ? "esxcli system hostname set --fqdn=$quoted" : "esxcli system hostname set --host=$quoted";
	my ($exit_status, $output) = $self->execute($hostname_command);
	if (!defined($output) || ($exit_status && $exit_status ne '0')) {
		($exit_status, $output) = $self->execute("esxcli system hostname set --host=$quoted");
	}
	if (!defined($output) || ($exit_status && $exit_status ne '0')) {
		notify($ERRORS{'WARNING'}, 0, "failed to set ESXi hostname to $public_hostname");
		return;
	}
	
	notify($ERRORS{'OK'}, 0, "set ESXi hostname on $computer_node_name to $public_hostname");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 update_resolv_conf

 Parameters  : @dns_servers
 Returns     : boolean
 Description : esxcli network ip dns server add. Replaces /etc/resolv.conf
               edits (ESXi regenerates resolv.conf).

=cut

sub update_resolv_conf {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $computer_name = $self->data->get_computer_short_name();
	my @dns_servers = @_;
	if (!@dns_servers) {
		@dns_servers = $self->data->get_management_node_public_dns_servers();
	}
	if (!@dns_servers) {
		notify($ERRORS{'DEBUG'}, 0, "no DNS servers supplied for $computer_name");
		return 1;
	}
	
	for my $dns_server (@dns_servers) {
		my ($exit_status, $output) = $self->execute("esxcli network ip dns server add --server=$dns_server");
		if (!defined($output)) {
			notify($ERRORS{'WARNING'}, 0, "failed to add DNS server $dns_server on $computer_name");
			return;
		}
			if ($exit_status && $exit_status ne '0' && !grep(/already|duplicate/i, @$output)) {
				# retry una vez (IO errors esporadicos de hostd)
				sleep 5;
				($exit_status, $output) = $self->execute("esxcli network ip dns server add --server=$dns_server");
			}
			if (!defined($output) || ($exit_status && $exit_status ne '0' && !grep(/already|duplicate/i, @$output))) {
			notify($ERRORS{'WARNING'}, 0, "failed to add DNS server $dns_server on $computer_name, output:\n" . join("\n", @$output));
			return;
		}
	}
	
	notify($ERRORS{'DEBUG'}, 0, "configured DNS servers on $computer_name via esxcli: " . join(', ', @dns_servers));
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 synchronize_time

 Parameters  : none
 Returns     : boolean
 Description : Configures NTP with esxcli system ntp set. Skip Linux rdate
               and ntpd service files.

=cut

sub synchronize_time {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}
	
	my $computer_node_name = $self->data->get_computer_node_name();
	my $management_node_hostname = $self->data->get_management_node_hostname();
	
	my $variable_name = "timesource|$management_node_hostname";
	my $variable_name_global = "timesource|global";
	
	my $time_source_variable;
	if (is_variable_set($variable_name)) {
		$time_source_variable = get_variable($variable_name);
	}
	elsif (is_variable_set($variable_name_global)) {
		$time_source_variable = get_variable($variable_name_global);
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "unable to sync time, neither '$variable_name' or '$variable_name_global' time source variable is set in database");
		return;
	}
	
	my @time_sources = split(/[,; ]+/, $time_source_variable);
	my $server_args = join(' ', map { "--server=$_" } @time_sources);
	my $command = "esxcli system ntp set --enabled=true $server_args";
	my ($exit_status, $output) = $self->execute($command);
	if (!defined($output) || ($exit_status && $exit_status ne '0')) {
		notify($ERRORS{'WARNING'}, 0, "failed to configure NTP on $computer_node_name via esxcli, output:\n" . (defined($output) ? join("\n", @$output) : '<undef>'));
		return;
	}
	
	$self->execute("chkconfig ntpd on");
	$self->execute("/etc/init.d/ntpd restart");
	
	notify($ERRORS{'DEBUG'}, 0, "configured NTP on $computer_node_name via esxcli system ntp set");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 enable_firewall_port

 Parameters  : $protocol, $port, $scope (optional)
 Returns     : 1 if succeeded, 0 otherwise
 Description : Enables the ESXi firewall ruleset that matches the port.
               Replaces Linux iptables/firewalld. Fixes the copy-paste
               osx class-check bug in the previous stub.

=cut

sub enable_firewall_port {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my ($protocol, $port, $scope) = @_;
	if (!$protocol || !$port) {
		notify($ERRORS{'WARNING'}, 0, "protocol and port arguments are required");
		return;
	}
	
	my @rulesets = $self->_find_rulesets_for_port($protocol, $port);
	if (!@rulesets) {
		notify($ERRORS{'DEBUG'}, 0, "no ESXi firewall ruleset found for $protocol/$port, treating as success (hostd may already allow it)");
		return 1;
	}
	
	my $allowed = $scope;
	if (!$allowed || $allowed =~ /^(0\.0\.0\.0\/0|any)$/i) {
		$allowed = 'all';
	}
	
	for my $ruleset (@rulesets) {
		$self->_enable_esxi_ruleset($ruleset, $allowed);
	}
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 disable_firewall_port

 Parameters  : $protocol, $port, $scope (optional)
 Returns     : boolean
 Description : Skip disabling ESXi rulesets. Turning off sshServer would
               lock the management node out of the guest.

=cut

sub disable_firewall_port {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	notify($ERRORS{'DEBUG'}, 0, "skipping disable_firewall_port on ESXi to avoid locking out management SSH");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 service_exists

 Parameters  : $service_name
 Returns     : boolean
 Description : SSH/TSM-SSH is treated as present. Other Linux service names
               do not exist on ESXi.

=cut

sub service_exists {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $service_name = shift;
	if (!$service_name) {
		notify($ERRORS{'WARNING'}, 0, "service name was not passed as an argument");
		return;
	}
	
	if ($service_name =~ /^(sshd|ssh|TSM-SSH)$/i) {
		return 1;
	}
	return 0;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 start_service

 Parameters  : $service_name
 Returns     : boolean
 Description : Starts TSM-SSH via vim-cmd. No-op for unknown services.

=cut

sub start_service {
	my $self = shift;
	return $self->_control_esxi_service('start', @_);
}

sub stop_service {
	my $self = shift;
	# Never stop SSH; management node would lose access
	my $service_name = $_[0] || '';
	if ($service_name =~ /^(sshd|ssh|TSM-SSH|ext_sshd)$/i) {
		notify($ERRORS{'DEBUG'}, 0, "not stopping $service_name on ESXi");
		return 1;
	}
	return 1;
}

sub restart_service {
	my $self = shift;
	return $self->_control_esxi_service('restart', @_);
}

sub enable_service {
	my $self = shift;
	return $self->_control_esxi_service('enable', @_);
}

sub disable_service {
	my $self = shift;
	my $service_name = $_[0] || '';
	if ($service_name =~ /^(sshd|ssh|TSM-SSH)$/i) {
		notify($ERRORS{'DEBUG'}, 0, "not disabling $service_name on ESXi");
		return 1;
	}
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 get_cpu_core_count

 Parameters  : none
 Returns     : integer
 Description : esxcli hardware cpu global get. Replaces /proc/cpuinfo.
               Fixes the osx class-check bug in the previous stub.

=cut

sub get_cpu_core_count {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $computer_node_name = $self->data->get_computer_node_name();
	my ($exit_status, $output) = $self->execute("esxcli hardware cpu global get");
	if (defined($output)) {
		my ($cores) = map { /CPU Cores:\s*(\d+)/i ? $1 : () } @$output;
		if ($cores) {
			notify($ERRORS{'DEBUG'}, 0, "retrieved $computer_node_name CPU core count via esxcli: $cores");
			return $cores;
		}
	}
	
	# Fallback: count processors in /proc/cpuinfo if the ramdisk exposes it
	($exit_status, $output) = $self->execute("grep -c ^processor /proc/cpuinfo");
	if (defined($output) && $output->[0] && $output->[0] =~ /^(\d+)/) {
		return $1;
	}
	
	notify($ERRORS{'WARNING'}, 0, "unable to determine CPU core count on $computer_node_name");
	return;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 get_cpu_speed

 Parameters  : none
 Returns     : integer (MHz)
 Description : esxcli hardware cpu list.

=cut

sub get_cpu_speed {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my ($exit_status, $output) = $self->execute("esxcli hardware cpu list");
	if (defined($output)) {
		my ($mhz) = map { /CPU Speed:\s*(\d+)/i ? $1 : () } @$output;
		return $mhz if $mhz;
	}
	return;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 get_total_memory

 Parameters  : none
 Returns     : integer (MB)
 Description : esxcli hardware memory get. Replaces Linux dmesg parse.

=cut

sub get_total_memory {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my ($exit_status, $output) = $self->execute("esxcli hardware memory get");
	if (defined($output)) {
		my ($bytes) = map { /Physical Memory:\s*(\d+)/i ? $1 : () } @$output;
		if ($bytes) {
			return int($bytes / 1024 / 1024);
		}
	}
	return;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 get_product_name

 Parameters  : none
 Returns     : string
 Description : vmware -v / esxcli system version get. Replaces
               /etc/redhat-release.

=cut

sub get_product_name {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	return $self->{product_name} if defined($self->{product_name});
	
	my $computer_name = $self->data->get_computer_short_name();
	my ($exit_status, $output) = $self->execute("vmware -v");
	if (defined($output) && $output->[0] && $output->[0] =~ /\w/) {
		$self->{product_name} = $output->[0];
		notify($ERRORS{'OK'}, 0, "determined ESXi product name on $computer_name: '$self->{product_name}'");
		return $self->{product_name};
	}
	
	($exit_status, $output) = $self->execute("esxcli system version get");
	if (defined($output)) {
		my ($product) = map { /Product:\s*(.+)/i ? $1 : () } @$output;
		my ($version) = map { /Version:\s*(.+)/i ? $1 : () } @$output;
		if ($product) {
			$self->{product_name} = $version ? "$product $version" : $product;
			notify($ERRORS{'OK'}, 0, "determined ESXi product name on $computer_name: '$self->{product_name}'");
			return $self->{product_name};
		}
	}
	
	notify($ERRORS{'WARNING'}, 0, "unable to determine ESXi product name on $computer_name");
	return;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 is_64_bit

 Parameters  : none
 Returns     : 1
 Description : All supported ESXi releases are 64-bit.

=cut

sub is_64_bit {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 check_connection_on_port

 Parameters  : $port
 Returns     : boolean
 Description : Uses esxcli network ip connection list. Replaces netstat.
               Fixes the osx class-check bug in the previous stub.

=cut

sub check_connection_on_port {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $port = shift;
	if (!$port) {
		notify($ERRORS{'WARNING'}, 0, "port variable was not passed as an argument");
		return;
	}
	
	my $computer_node_name = $self->data->get_computer_node_name();
	my $remote_ip = $self->data->get_reservation_remote_ip();
	
	my $port_connection_info = $self->get_port_connection_info();
	if (!$port_connection_info) {
		return 0;
	}
	
	for my $protocol (keys %$port_connection_info) {
		next if !defined($port_connection_info->{$protocol}{$port});
		for my $connection (@{$port_connection_info->{$protocol}{$port}}) {
			my $connection_remote_ip = $connection->{remote_ip};
			if ($remote_ip && $connection_remote_ip eq $remote_ip) {
				notify($ERRORS{'DEBUG'}, 0, "connection to $computer_node_name detected from reservation remote IP: $connection_remote_ip port $port");
				return 1;
			}
			if ($connection_remote_ip && $connection_remote_ip !~ /^(127\.|0\.0\.0\.0)/) {
				notify($ERRORS{'DEBUG'}, 0, "connection to $computer_node_name detected on port $port from $connection_remote_ip");
				$self->data->set_reservation_remote_ip($connection_remote_ip) if $connection_remote_ip;
				return 1;
			}
		}
	}
	
	notify($ERRORS{'DEBUG'}, 0, "connection to $computer_node_name NOT detected on port $port");
	return 0;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 get_port_connection_info

 Parameters  : none
 Returns     : hash reference
 Description : Parses esxcli network ip connection list (BusyBox has no
               GNU netstat -anp).

=cut

sub get_port_connection_info {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my ($exit_status, $output) = $self->execute("esxcli network ip connection list");
	if (!defined($output)) {
		# BusyBox netstat fallback
		($exit_status, $output) = $self->execute("netstat -an");
		if (!defined($output)) {
			notify($ERRORS{'WARNING'}, 0, "failed to retrieve connection list");
			return;
		}
	}
	
	my $connection_info = {};
	for my $line (@$output) {
		next unless $line =~ /ESTABLISHED/i;
		# tcp  0  0  192.168.1.10:22  10.0.0.1:54321  ESTABLISHED
		my ($protocol, $local_ip, $port, $remote_ip) = $line =~ /^(\w+).+?\s([\d\.]+):(\d+)\s+([\d\.]+):/i;
		next unless $protocol && $port;
		push @{$connection_info->{$protocol}{$port}}, {
			remote_ip => $remote_ip,
			local_ip => $local_ip,
		};
	}
	return $connection_info;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 is_connected

 Parameters  : none
 Returns     : boolean
 Description : Checks for an established connection to the public IP on
               port 22 using ESXi connection listing.

=cut

sub is_connected {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	return $self->check_connection_on_port(22);
}

#//////////////////////////////////////////////////////////////////////////////

=head2 shutdown

 Parameters  : none
 Returns     : boolean
 Description : esxcli system shutdown poweroff. Replaces /sbin/shutdown -h.

=cut

sub shutdown {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $computer_node_name = $self->data->get_computer_node_name();
	
	if ($self->wait_for_ssh(0)) {
		my $command = 'esxcli system shutdown poweroff --reason="VCL capture"';
		notify($ERRORS{'DEBUG'}, 0, "attempting to shut down $computer_node_name by executing '$command'");
		$self->execute({
			command => $command,
			timeout => 30,
			max_attempts => 1,
			display_output => 0,
		});
		
		if ($self->provisioner->wait_for_power_off(300, 10)) {
			notify($ERRORS{'OK'}, 0, "gracefully shut down $computer_node_name via esxcli system shutdown poweroff");
			return 1;
		}
	}
	
	$self->provisioner->power_off() || return;
	if ($self->provisioner->wait_for_power_off(300, 10)) {
		notify($ERRORS{'OK'}, 0, "forcefully powered off $computer_node_name using the provisioning module");
		return 1;
	}
	notify($ERRORS{'WARNING'}, 0, "failed to shut down $computer_node_name");
	return;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 reboot

 Parameters  : none
 Returns     : boolean
 Description : esxcli system shutdown reboot.

=cut

sub reboot {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $computer_node_name = $self->data->get_computer_node_name();
	my $reboot_start_time = time();
	
	if ($self->wait_for_ssh(0)) {
		my $command = 'esxcli system shutdown reboot --reason="VCL"';
		$self->execute({
			command => $command,
			timeout => 30,
			max_attempts => 1,
			display_output => 0,
		});
		if ($self->wait_for_reboot()) {
			my $reboot_duration = (time() - $reboot_start_time);
			notify($ERRORS{'OK'}, 0, "gracefully rebooted $computer_node_name via esxcli, took $reboot_duration seconds");
			return 1;
		}
	}
	
	if ($self->provisioner->can('power_reset') && $self->provisioner->power_reset()) {
		if ($self->wait_for_reboot()) {
			notify($ERRORS{'OK'}, 0, "rebooted $computer_node_name using the provisioning module");
			return 1;
		}
	}
	
	notify($ERRORS{'WARNING'}, 0, "failed to reboot $computer_node_name");
	return;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 nfs_mount_share

 Parameters  : $remote_nfs_share, $local_mount_directory, ...
 Returns     : boolean
 Description : Mounts NFS as an ESXi datastore (esxcli storage nfs add /
               esxcfg-nas). Replaces Linux mount -t nfs.

=cut

sub nfs_mount_share {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my ($remote_nfs_share, $local_mount_directory) = @_;
	if (!defined($remote_nfs_share) || !defined($local_mount_directory)) {
		notify($ERRORS{'WARNING'}, 0, "remote NFS share and local directory arguments are required");
		return;
	}
	
	my ($host, $volume) = $remote_nfs_share =~ /^([^:]+):(.+)$/;
	if (!$host || !$volume) {
		notify($ERRORS{'WARNING'}, 0, "unable to parse NFS share: $remote_nfs_share");
		return;
	}
	
	my $datastore_name = $local_mount_directory;
	$datastore_name =~ s/^\/+//;
	$datastore_name =~ s/[\/\s]+/-/g;
	$datastore_name = "vcl-$datastore_name" if $datastore_name !~ /[A-Za-z]/;
	
	if ($self->is_nfs_share_mounted($remote_nfs_share, $local_mount_directory)) {
		return 1;
	}
	
	my $command = "esxcli storage nfs add --host=$host --share=$volume --volume-name=$datastore_name";
	my ($exit_status, $output) = $self->execute($command);
	if (defined($output) && (!$exit_status || $exit_status eq '0' || grep(/already/i, @$output))) {
		notify($ERRORS{'OK'}, 0, "mounted NFS datastore $datastore_name ($remote_nfs_share) via esxcli storage nfs add");
		return 1;
	}
	
	($exit_status, $output) = $self->execute("esxcfg-nas -a $datastore_name -o $host -s $volume");
	if (defined($output) && (!$exit_status || $exit_status eq '0' || grep(/already/i, @$output))) {
		notify($ERRORS{'OK'}, 0, "mounted NFS datastore $datastore_name via esxcfg-nas");
		return 1;
	}
	
	notify($ERRORS{'WARNING'}, 0, "failed to mount NFS share $remote_nfs_share as $datastore_name");
	return;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 nfs_unmount_share

 Parameters  : $local_mount_directory
 Returns     : boolean
 Description : Unmounts an ESXi NFS datastore via esxcli storage nfs remove
               or esxcfg-nas -d.

=cut

sub nfs_unmount_share {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $local_mount_directory = shift;
	if (!defined($local_mount_directory)) {
		notify($ERRORS{'WARNING'}, 0, "local mount directory argument was not supplied");
		return;
	}
	
	my $datastore_name = $local_mount_directory;
	$datastore_name =~ s/^\/+//;
	$datastore_name =~ s/[\/\s]+/-/g;
	
	my ($exit_status, $output) = $self->execute("esxcli storage nfs remove --volume-name=$datastore_name");
	if (defined($output) && (!$exit_status || $exit_status eq '0' || grep(/not found|does not exist/i, @$output))) {
		return 1;
	}
	
	($exit_status, $output) = $self->execute("esxcfg-nas -d $datastore_name");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 is_nfs_share_mounted

 Parameters  : $remote_nfs_share, $local_mount_directory
 Returns     : boolean
 Description : Checks esxcli storage nfs list / esxcfg-nas -l.

=cut

sub is_nfs_share_mounted {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my ($remote_nfs_share, $local_mount_directory) = @_;
	my @mounts = $self->get_nfs_mount_strings();
	if ($remote_nfs_share && grep { index($_, $remote_nfs_share) >= 0 } @mounts) {
		return 1;
	}
	if ($local_mount_directory && grep { index($_, $local_mount_directory) >= 0 } @mounts) {
		return 1;
	}
	return 0;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 get_nfs_mount_strings

 Parameters  : none
 Returns     : array
 Description : Lists ESXi NFS datastores.

=cut

sub get_nfs_mount_strings {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my @mounts;
	my ($exit_status, $output) = $self->execute("esxcli storage nfs list");
	if (defined($output)) {
		for my $line (@$output) {
			push @mounts, $line if $line =~ /\S/ && $line !~ /^(Volume|----)/;
		}
	}
	if (!@mounts) {
		($exit_status, $output) = $self->execute("esxcfg-nas -l");
		if (defined($output)) {
			push @mounts, @$output;
		}
	}
	return @mounts;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 configure_default_sshd

 Parameters  : none
 Returns     : 1
 Description : Skip Linux sshd_config / ext_sshd teardown.

=cut

sub configure_default_sshd {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	notify($ERRORS{'DEBUG'}, 0, "skipping Linux configure_default_sshd on ESXi");
	return $self->_ensure_ssh_enabled();
}

#//////////////////////////////////////////////////////////////////////////////

=head2 configure_ext_sshd

 Parameters  : none
 Returns     : 1
 Description : Skip. ESXi has a single TSM-SSH daemon, not ext_sshd.

=cut

sub configure_ext_sshd {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	notify($ERRORS{'DEBUG'}, 0, "skipping Linux configure_ext_sshd on ESXi");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 configure_rc_local

 Parameters  : none
 Returns     : 1
 Description : Skip Linux /etc/rc.local cleanup.

=cut

sub configure_rc_local {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	notify($ERRORS{'DEBUG'}, 0, "skipping Linux configure_rc_local on ESXi");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 clean_known_files

 Parameters  : none
 Returns     : 1
 Description : Skip Linux capture file-clear list (udev, syslog, ifcfg).

=cut

sub clean_known_files {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	notify($ERRORS{'DEBUG'}, 0, "skipping Linux clean_known_files on ESXi");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 generate_exclude_list_sample

 Parameters  : none
 Returns     : 1
 Description : Skip Linux /root/.vclcontrol sample file.

=cut

sub generate_exclude_list_sample {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 clear_private_keys

 Parameters  : none
 Returns     : 1
 Description : Skip Linux /root/.ssh identity cleanup. ESXi persists
               authorized_keys under /etc/ssh/keys-root.

=cut

sub clear_private_keys {
	my $self = shift;
	unless (ref($self) && $self->isa('VCL::Module')) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine can only be called as a VCL::Module module object method");
		return;
	}
	notify($ERRORS{'DEBUG'}, 0, "skipping Linux clear_private_keys on ESXi");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 stop_external_sshd

 Parameters  : none
 Returns     : 1
 Description : Skip. There is no ext_sshd on ESXi.

=cut

sub stop_external_sshd {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	return 1;
}

###############################################################################

=head1 PRIVATE HELPERS

=cut

#//////////////////////////////////////////////////////////////////////////////

=head2 _shell_quote

 Parameters  : $value
 Returns     : single-quoted shell-safe string

=cut

sub _shell_quote {
	my $self = shift;
	my $value = defined($_[0]) ? $_[0] : '';
	$value =~ s/'/'\\''/g;
	return "'$value'";
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _supports_esxcli_accounts

 Parameters  : none
 Returns     : boolean
 Description : True when `esxcli system account list` works (ESXi 6+).

=cut

sub _supports_esxcli_accounts {
	my $self = shift;
	return $self->{supports_esxcli_accounts} if defined($self->{supports_esxcli_accounts});
	
	my ($exit_status, $output) = $self->execute("esxcli system account list");
	if (defined($output) && (!$exit_status || $exit_status eq '0') && !grep(/unknown|not (a|found|valid)|error/i, @$output)) {
		$self->{supports_esxcli_accounts} = 1;
	}
	else {
		$self->{supports_esxcli_accounts} = 0;
		notify($ERRORS{'DEBUG'}, 0, "esxcli system account is not available, will use vim-cmd/useradd fallback");
	}
	return $self->{supports_esxcli_accounts};
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _add_esxi_account

 Parameters  : $username, $password
 Returns     : boolean

=cut

sub _add_esxi_account {
	my $self = shift;
	my ($username, $password) = @_;
	$password = getpw(15) if !$password;
	
	my $quoted_user = $self->_shell_quote($username);
	my $quoted_pass = $self->_shell_quote($password);
	
	if ($self->_supports_esxcli_accounts()) {
		my $command = "esxcli system account add -d 'VCL reservation user' -i $quoted_user -p $quoted_pass -c $quoted_pass";
		my ($exit_status, $output) = $self->execute($command);
		if (defined($output) && (!$exit_status || $exit_status eq '0' || grep(/already exists/i, @$output))) {
			notify($ERRORS{'OK'}, 0, "added ESXi account $username via esxcli system account add");
			return 1;
		}
		notify($ERRORS{'WARNING'}, 0, "esxcli system account add failed for $username, output:\n" . (defined($output) ? join("\n", @$output) : '<undef>'));
	}
	
	# Legacy ESXi 4.x: useradd exists on some images
	my ($exit_status, $output) = $self->execute("useradd -M $username");
	if (defined($output) && (!$exit_status || $exit_status eq '0' || grep(/already exists/i, @$output))) {
		return $self->set_password($username, $password);
	}
	
	notify($ERRORS{'WARNING'}, 0, "failed to add ESXi account $username");
	return;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _ensure_ssh_enabled

 Parameters  : none
 Returns     : boolean
 Description : vim-cmd hostsvc/enable_ssh + start_ssh.

=cut

sub _ensure_ssh_enabled {
	my $self = shift;
	$self->execute("vim-cmd hostsvc/enable_ssh");
	$self->execute("vim-cmd hostsvc/start_ssh");
	$self->execute("chkconfig SSH on");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _enable_esxi_ruleset

 Parameters  : $ruleset_name, $allowed_ip (optional: IP or 'all')
 Returns     : boolean

=cut

sub _enable_esxi_ruleset {
	my $self = shift;
	my ($ruleset_name, $allowed_ip) = @_;
	return if !$ruleset_name;
	
	my ($exit_status, $output) = $self->execute("esxcli network firewall ruleset set --ruleset-id=$ruleset_name --enabled true");
	if (!defined($output) || ($exit_status && $exit_status ne '0' && !grep(/not found|no such/i, @$output))) {
		if (defined($output) && grep(/not found|no such|unknown/i, @$output)) {
			notify($ERRORS{'DEBUG'}, 0, "ESXi firewall ruleset $ruleset_name does not exist on this version");
			return 1;
		}
		return 1 if !defined($output);
	}
	
	if ($allowed_ip && $allowed_ip =~ /^all$/i) {
		$self->execute("esxcli network firewall ruleset set --ruleset-id=$ruleset_name --allowed-all true");
	}
	elsif ($allowed_ip) {
		my ($ip_exit, $ip_output) = $self->execute("esxcli network firewall ruleset allowedip add --ruleset-id=$ruleset_name --ip-address=$allowed_ip");
		if (defined($ip_output) && grep(/allowed-all/i, @$ip_output)) {
			notify($ERRORS{'DEBUG'}, 0, "ruleset $ruleset_name already allows all IP addresses");
		}
	}
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _find_rulesets_for_port

 Parameters  : $protocol, $port
 Returns     : list of ruleset names

=cut

sub _find_rulesets_for_port {
	my $self = shift;
	my ($protocol, $port) = @_;
	
	my %static_map = (
		'22' => [qw(sshServer)],
		'80' => [qw(webAccess httpClient)],
		'443' => [qw(webAccess vSphereClient httpsHostAgent)],
		'902' => [qw(vpxHeartbeats)],
	);
	
	my @rulesets;
	push @rulesets, @{$static_map{$port}} if $static_map{$port};
	
	my ($exit_status, $output) = $self->execute("esxcli network firewall ruleset rule list");
	if (defined($output)) {
		for my $line (@$output) {
			next unless $line =~ /$port/;
			next if $protocol && $line !~ /$protocol/i;
			if ($line =~ /^(\S+)\s+/) {
				my $name = $1;
				next if $name =~ /^(Ruleset|----)/;
				push @rulesets, $name unless grep { $_ eq $name } @rulesets;
			}
		}
	}
	
	return @rulesets;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _control_esxi_service

 Parameters  : $action, $service_name
 Returns     : boolean

=cut

sub _control_esxi_service {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my ($action, $service_name) = @_;
	if (!$service_name) {
		notify($ERRORS{'WARNING'}, 0, "service name was not passed as an argument");
		return;
	}
	
	if ($service_name =~ /^(sshd|ssh|TSM-SSH)$/i) {
		return $self->_ensure_ssh_enabled();
	}
	
	notify($ERRORS{'DEBUG'}, 0, "no ESXi equivalent for Linux service $service_name ($action), treating as success");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _unmount_esxi_nas_datastores

 Parameters  : none
 Returns     : boolean
 Description : Removes NAS datastores whose names match the optional
               ESXI_STORAGE_NAME_PREFIX from vcld.conf.

=cut

sub _unmount_esxi_nas_datastores {
	my $self = shift;
	my $vcld_config = $self->local_read_vcld_config("/etc/vcl/vcld.conf");
	my $prefix = $vcld_config->{"ESXI_STORAGE_NAME_PREFIX"} if $vcld_config;
	return 1 if !$prefix;
	
	my ($exit_status, $output) = $self->execute("esxcfg-nas -l");
	return 1 if !defined($output);
	
	for my $line (@$output) {
		if ($line =~ /^(\Q$prefix\E\S*)/) {
			my $nas_name = $1;
			$nas_name =~ s/:$//;
			$self->execute("esxcli storage nfs remove --volume-name=$nas_name");
			$self->execute("esxcfg-nas -d $nas_name");
		}
	}
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _configure_nested_lab_storage

 Parameters  : none
 Returns     : boolean
 Description : Original ESXi.pm student-lab extras: mount per-user NFS and
               register VMX files. Skipped unless ESXI_STORAGE_* keys exist
               in vcld.conf. Does not use Linux useradd/passwd/pam.

=cut

sub _configure_nested_lab_storage {
	my $self = shift;
	
	my $vcld_config = $self->local_read_vcld_config("/etc/vcl/vcld.conf");
	return 1 if !$vcld_config;
	
	my $esxi_storage_name_prefix = $vcld_config->{"ESXI_STORAGE_NAME_PREFIX"};
	my $esxi_storage_address = $vcld_config->{"ESXI_STORAGE_ADDRESS"};
	my $esxi_storage_volume = $vcld_config->{"ESXI_STORAGE_VOLUME"};
	if (!$esxi_storage_name_prefix || !$esxi_storage_address || !$esxi_storage_volume) {
		notify($ERRORS{'DEBUG'}, 0, "ESXI_STORAGE_* is not fully set in vcld.conf, skipping nested-lab NAS/registervm");
		return 1;
	}
	
	my $username = $self->data->get_user_login_id();
	my $computer_node_name = $self->data->get_computer_node_name();
	my $management_node_keys = $self->data->get_management_node_keys();
	my $nas_name = "$esxi_storage_name_prefix-$username";
	
	# Keep the original BusyBox-safe sed -f approach (ESXi sed is not GNU sed)
	my @commands = (
		"esxcli storage nfs add --host=$esxi_storage_address --share=$esxi_storage_volume/$username --volume-name=$nas_name || esxcfg-nas -a $nas_name -o $esxi_storage_address -s $esxi_storage_volume/$username",
		"sleep 3",
		"echo /uuid.action/c > /tmp/vcl-esxi.sed",
		"echo \\\$ a uuid.action = \\\"keep\\\" >> /tmp/vcl-esxi.sed",
		"find /vmfs/volumes/$nas_name/ -name '*.vmx' -exec sed -f /tmp/vcl-esxi.sed -i {} \\;",
		"rm -f /tmp/vcl-esxi.sed",
		"find /vmfs/volumes/$nas_name/ -name '*.vmx' -exec vim-cmd solo/registervm {} \\;",
	);
	
	foreach my $command (@commands) {
		my ($exit_status, $output) = run_ssh_command($computer_node_name, $management_node_keys, $command, "root");
		if (!defined($output)) {
			notify($ERRORS{'WARNING'}, 0, "failed to run SSH command: $command");
			return;
		}
	}
	
	notify($ERRORS{'OK'}, 0, "mounted nested-lab NAS $nas_name and registered VMX files on $computer_node_name");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 local_read_vcld_config

 Parameters  : full path to vcld.conf
 Returns     : hash reference
 Description : Reads key=value pairs from vcld.conf. Does not die if the
               file is missing.

=cut

sub local_read_vcld_config {
	# Accept both function and method invocation
	shift if (ref($_[0]));
	my ($config_file) = @_;
	my $vcld_config = {};
	return $vcld_config if !$config_file || !-r $config_file;
	
	if (!open(CONFIG, '<', $config_file)) {
		notify($ERRORS{'DEBUG'}, 0, "unable to open vcld.conf file: $config_file");
		return $vcld_config;
	}
	while (<CONFIG>) {
		chomp;
		s/#.*//;
		s/^\s+//;
		s/\s+$//;
		next unless length;
		my ($var, $value) = split(/\s*=\s*/, $_, 2);
		next unless defined($var) && length($var);
		$vcld_config->{$var} = $value;
	}
	close(CONFIG);
	return $vcld_config;
}

#//////////////////////////////////////////////////////////////////////////////

sub execute {
	my $self = shift;
	
	# retry hostd: esxcli/vim-cmd pueden fallar con 503/Connection refused
	# mientras hostd arranca tras un load/reload del guest ESXi
	my ($exit_status, $output);
	for my $attempt (1 .. 3) {
		($exit_status, $output) = $self->SUPER::execute(@_);
		last if !defined($output);
		last if !grep(/(503 Service Unavailable|Connection refused)/, @$output);
		notify($ERRORS{'DEBUG'}, 0, "hostd not ready (attempt $attempt/3), retrying in 10s");
		sleep 10;
	}
	return ($exit_status, $output);
}

sub get_os_type {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $computer_node_name = $self->data->get_computer_node_name() || return;
	
	my $command = 'uname -a';
	my ($exit_status, $output) = $self->execute($command, 0);
	if (!defined($output)) {
		notify($ERRORS{'WARNING'}, 0, "failed to run command to determine OS type currently installed on $computer_node_name");
		return;
	}
	elsif ($exit_status ne '0') {
		notify($ERRORS{'WARNING'}, 0, "error occurred attempting to determine OS type currently installed on $computer_node_name\ncommand: '$command'\noutput:\n" . join("\n", @$output));
		return;
	}
	elsif (grep(/vmkernel|esxi/i, @$output)) {
		notify($ERRORS{'DEBUG'}, 0, "VMware ESXi (VMkernel) OS is currently installed on $computer_node_name, reporting OS type as 'linux'");
		return 'linux';
	}
	else {
		# fall back to the base implementation for anything else
		return $self->SUPER::get_os_type();
	}
}

sub get_private_mac_address {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $computer_node_name = $self->data->get_computer_node_name() || return;
	my $command = "esxcli network ip interface list | grep -A20 -m1 'Name\|MTU' | grep -m1 'MAC Address' | awk '{print \$NF}'";
	my ($exit_status, $output) = $self->execute($command, 0);
	if (!defined($output)) {
		notify($ERRORS{'WARNING'}, 0, "failed to execute esxcli to determine private MAC address on $computer_node_name");
		return;
	}
	elsif ($exit_status ne '0' || !grep(/:/, @$output)) {
		# fallback: obtener via esxcli network ip interface ipv4 get (mac no aparece) -> usar interfaz vmk0
		($exit_status, $output) = $self->execute("esxcli network ip interface list | grep -m1 'MAC Address' | awk '{print \$NF}'", 0);
		if (!defined($output) || !grep(/:/, @$output)) {
			notify($ERRORS{'WARNING'}, 0, "unable to determine private MAC address on $computer_node_name");
			return;
		}
	}
	my $mac_address = $output->[0];
	chomp $mac_address;
	notify($ERRORS{'DEBUG'}, 0, "retrieved private MAC address on $computer_node_name: $mac_address");
	return lc($mac_address);
}

sub get_public_mac_address {
	my $self = shift;
	return $self->get_private_mac_address();
}



#//////////////////////////////////////////////////////////////////////////////

=head2 get_public_interface_name

 Parameters  : none
 Returns     : string
 Description : ESXi nested uses a single VMkernel NIC (vmk0) for both private
               and public traffic (same LAN). The base OS.pm logic rejects an
               interface whose only IP equals the private IP, so override to
               return the private interface name.

=cut

sub get_public_interface_name {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $private_interface_name = $self->get_private_interface_name();
	if (!$private_interface_name) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine public interface name, private interface name could not be determined");
		return;
	}

	notify($ERRORS{'DEBUG'}, 0, "ESXi nested: public and private interface are the same ($private_interface_name)");
	return $private_interface_name;
}


#//////////////////////////////////////////////////////////////////////////////

=head2 get_default_gateway

 Parameters  : none
 Returns     : string
 Description : ESXi nested: la ruta default ya esta configurada en el guest
               (vmk0 -> 192.168.0.1). El OS.pm base depende de la key
               'default_gateway' del network config, que puede faltar si
               esxcli route list falla intermitentemente. Devuelve el gateway
               del management node directamente.

=cut


sub get_default_gateway {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $gateway = $self->get_correct_default_gateway();
	if (!$gateway) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine default gateway");
		return;
	}

	notify($ERRORS{'DEBUG'}, 0, "ESXi nested: returning management node default gateway: $gateway");
	return $gateway;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _get_vmkernel_portgroup

 Parameters  : $interface_name (vmkN)
 Returns     : portgroup string or undef
 Description : Parses `esxcli network ip interface list` for the Portgroup
               attached to the given VMkernel NIC. Used before recreating
               the NIC so it is re-added on the same portgroup.

=cut

sub _get_vmkernel_portgroup {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $interface_name = shift || '';
	if ($interface_name !~ /^vmk\d+$/) {
		notify($ERRORS{'WARNING'}, 0, "invalid VMkernel interface name: '$interface_name'");
		return;
	}
	
	my ($exit_status, $output) = $self->execute('esxcli network ip interface list');
	if (!defined($output) || !@$output) {
		notify($ERRORS{'DEBUG'}, 0, "unable to list VMkernel interfaces while looking up portgroup for $interface_name");
		return;
	}
	
	my $in_block = 0;
	for my $line (@$output) {
		if ($line =~ /^(vmk\d+)\s*$/ || $line =~ /^\s*Name:\s+(vmk\d+)/) {
			$in_block = ($1 eq $interface_name) ? 1 : 0;
			next;
		}
		if ($in_block && $line =~ /^\s*Port\s*Group:\s+(.+?)\s*$/i) {
			my $portgroup = $1;
			notify($ERRORS{'DEBUG'}, 0, "$interface_name portgroup: $portgroup");
			return $portgroup;
		}
	}
	
	notify($ERRORS{'DEBUG'}, 0, "portgroup for $interface_name was not present in esxcli network ip interface list output");
	return;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _enable_follow_hardware_mac

 Parameters  : none
 Returns     : boolean
 Description : Sets /Net/FollowHardwareMac=1 so a cloned nested ESXi guest
               binds vmk0 to the hypervisor-assigned vNIC MAC instead of the
               MAC baked into esx.conf. Idempotent. Does not drop SSH.

=cut

sub _enable_follow_hardware_mac {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $computer_name = $self->data->get_computer_node_name();
	my $command = 'esxcli system settings advanced set -o /Net/FollowHardwareMac -i 1';
	my ($exit_status, $output) = $self->execute($command);
	if (!defined($output) || (defined($exit_status) && $exit_status ne '0')) {
		($exit_status, $output) = $self->execute('esxcfg-advcfg -s 1 /Net/FollowHardwareMac');
		if (!defined($output) || (defined($exit_status) && $exit_status ne '0' && !grep(/already|success/i, @$output))) {
			notify($ERRORS{'WARNING'}, 0, "failed to enable /Net/FollowHardwareMac on $computer_name");
			return;
		}
	}
	
	notify($ERRORS{'OK'}, 0, "enabled /Net/FollowHardwareMac on $computer_name so clones follow the hypervisor-assigned vNIC MAC");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _scrub_esxi_capture_identity

 Parameters  : none
 Returns     : boolean
 Description : Clears sticky identity that survives DHCP-only prep:
                 * /system/uuid in esx.conf (clones generate a new UUID)
                 * dhclient lease files
               Does not drop SSH. Does not sed-edit vmk MAC/IP keys while
               hostd is running; those are cleared by recreating vmk0.

=cut

sub _scrub_esxi_capture_identity {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $computer_name = $self->data->get_computer_node_name();
	
	# William Lam nested-ESXi clone prep: delete /system/uuid so the next
	# boot of a clone generates a new UUID. BusyBox sed -i is available.
	my ($uuid_exit, $uuid_output) = $self->execute("sed -i 's#/system/uuid.*##' /etc/vmware/esx.conf");
	if (!defined($uuid_output) || (defined($uuid_exit) && $uuid_exit ne '0')) {
		notify($ERRORS{'WARNING'}, 0, "failed to clear /system/uuid from esx.conf on $computer_name");
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "cleared /system/uuid from esx.conf on $computer_name");
	}
	
	$self->execute('rm -f /etc/dhclient*leases /etc/dhclient-*.leases /var/lib/dhclient/dhclient*.leases');
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _precapture_generalize_script

 Parameters  : $interface_name, $portgroup
 Returns     : BusyBox ash script string
 Description : Guest-side Instant Clone-style vmk recreate + DHCP. Intended
               to run detached (SIGHUP ignored) so the capture SSH session
               can close before the management NIC is destroyed.

=cut

sub _precapture_generalize_script {
	my $self = shift;
	my $interface_name = shift || 'vmk0';
	my $portgroup = shift || 'Management Network';
	
	$interface_name =~ s/[^A-Za-z0-9]//g;
	$interface_name = 'vmk0' if $interface_name !~ /^vmk\d+$/;
	$portgroup =~ s/[^A-Za-z0-9 _.-]//g;
	$portgroup = 'Management Network' if !length($portgroup);
	
	return <<'SCRIPT_TOP' . <<"SCRIPT_VARS" . <<'SCRIPT_BODY';
#!/bin/sh
# VCL nested ESXi pre_capture generalize.
# Runs detached: the MN SSH session must not be the process that removes vmk0.
trap '' HUP
log() { echo "VCL_ESXI_PRECAPTURE: $*"; }
uname_s=$(uname -a 2>/dev/null)
log "begin $uname_s"
SCRIPT_TOP
INTERFACE='$interface_name'
PORTGROUP='$portgroup'
SCRIPT_VARS
# Give the MN time to close SSH cleanly before the management NIC goes away.
sleep 5

# Recreate last so FollowHardwareMac/UUID (set over SSH) are already on disk.
# Portgroup is parsed on the MN before this script starts. Empty -> default.
if [ -z "$PORTGROUP" ]; then
	PORTGROUP="Management Network"
	log "portgroup empty, defaulting to Management Network"
else
	log "$INTERFACE portgroup=$PORTGROUP"
fi

log "recreating $INTERFACE (Instant Clone style) pg=$PORTGROUP then DHCP"
localcli network ip interface set -e false -i "$INTERFACE" || true
localcli network ip interface remove -i "$INTERFACE" || true

if ! localcli network ip interface add -i "$INTERFACE" -p "$PORTGROUP"; then
	log "add with parsed portgroup failed, trying Management Network then VM Network"
	localcli network ip interface add -i "$INTERFACE" -p "Management Network" || localcli network ip interface add -i "$INTERFACE" -p "VM Network" || {
		log "failed to re-add $INTERFACE"
		exit 1
	}
fi

if localcli network ip interface ipv4 set -i "$INTERFACE" -t dhcp; then
	log "set $INTERFACE dhcp"
else
	esxcli network ip interface ipv4 set --interface-name="$INTERFACE" --type=dhcp || log "failed to set DHCP on $INTERFACE"
fi

rm -f /etc/dhclient*leases /etc/dhclient-*.leases /var/lib/dhclient/dhclient*.leases 2>/dev/null || true

# Flush esx.conf so a subsequent hypervisor power_off keeps the generalized NIC.
if [ -x /sbin/auto-backup.sh ]; then
	/sbin/auto-backup.sh >/dev/null 2>&1 || log "auto-backup.sh skipped"
else
	log "auto-backup.sh not present"
fi

# After auto-backup so the bootbank has the new vmk0/DHCP, drop UUID from the
# live esx.conf. hostd may rewrite it; this matches nested-ESXi clone prep.
sed -i 's#/system/uuid.*##' /etc/vmware/esx.conf 2>/dev/null || true

sleep 3
log "done"
localcli network ip interface ipv4 get 2>/dev/null || true
touch /scratch/vcl-precapture-generalize.done
exit 0
SCRIPT_BODY
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _generalize_management_vmkernel

 Parameters  : $interface_name (optional, default vmk0)
 Returns     : boolean (true if the detached vmk recreate script was launched)
 Description : Capture-time nested ESXi generalize over SSH.
               Complementary to _bootstrap_nested_management_network (load-time
               GuestOps, static reservation IP). This path:

                 1. Enables /Net/FollowHardwareMac (SSH stays up)
                 2. Scrubs /system/uuid and dhclient leases (SSH stays up)
                 3. Persists with auto-backup.sh
                 4. Launches a detached Instant Clone-style disable/remove/
                    re-add of the management VMkernel on the same portgroup,
                    then DHCP

               Recreating the NIC is what actually drops the baked MAC/IP from
               esx.conf; DHCP-only does not. The recreate is detached because
               removing vmk0 kills the capture SSH session. shutdown() later
               falls back to provisioner power_off if SSH does not return.

=cut

sub _generalize_management_vmkernel {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $interface_name = shift || 'vmk0';
	if ($interface_name !~ /^vmk\d+$/) {
		notify($ERRORS{'WARNING'}, 0, "refusing to generalize invalid VMkernel name '$interface_name', defaulting to vmk0");
		$interface_name = 'vmk0';
	}
	
	my $computer_name = $self->data->get_computer_node_name();
	notify($ERRORS{'OK'}, 0, "generalizing nested ESXi management VMkernel $interface_name on $computer_name (capture-time; complementary to post_load GuestOps)");
	
	# --- SSH-safe steps (do not destroy the management NIC yet) ---
	$self->_enable_follow_hardware_mac();
	$self->_scrub_esxi_capture_identity();
	
	my $portgroup = $self->_get_vmkernel_portgroup($interface_name) || 'Management Network';
	notify($ERRORS{'DEBUG'}, 0, "will recreate $interface_name on portgroup '$portgroup'");
	
	my ($backup_exit, $backup_output) = $self->execute('/sbin/auto-backup.sh');
	if (!defined($backup_output) || (defined($backup_exit) && $backup_exit ne '0')) {
		notify($ERRORS{'DEBUG'}, 0, "auto-backup.sh before vmk recreate returned " . (defined($backup_exit) ? $backup_exit : 'undef') . " on $computer_name");
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "persisted FollowHardwareMac/UUID via auto-backup.sh on $computer_name");
	}
	
	# --- Destructive step: recreate vmkN detached so this SSH session can close ---
	my $script_path = '/scratch/vcl-precapture-generalize.sh';
	my $log_path = '/scratch/vcl-precapture-generalize.log';
	my $done_path = '/scratch/vcl-precapture-generalize.done';
	my $script = $self->_precapture_generalize_script($interface_name, $portgroup);
	
	$self->execute("rm -f $done_path $log_path");
	if (!$self->create_text_file($script_path, $script)) {
		notify($ERRORS{'WARNING'}, 0, "failed to write $script_path on $computer_name; skipping vmk recreate (FollowHardwareMac/DHCP still apply)");
		return;
	}
	$self->execute("chmod 755 $script_path");
	
	# trap '' HUP in both the wrapper and the script: ESXi SSH sends SIGHUP
	# when the capture session closes, which would otherwise kill the recreate.
	my $launch = "/bin/sh -c 'trap \"\" HUP; /bin/sh $script_path >$log_path 2>&1 </dev/null &' ; echo VCL_ESXI_PRECAPTURE_LAUNCHED";
	my ($launch_exit, $launch_output) = $self->execute($launch, 0);
	if (!defined($launch_output) || !grep(/VCL_ESXI_PRECAPTURE_LAUNCHED/, @$launch_output)) {
		notify($ERRORS{'WARNING'}, 0, "failed to launch detached vmk generalize script on $computer_name; skipping recreate");
		return;
	}
	
	notify($ERRORS{'OK'}, 0, "launched detached $interface_name recreate+DHCP on $computer_name; waiting for it to finish (SSH may drop)");
	
	# Script: sleep 5 + disable/remove/add/dhcp + auto-backup + sleep 3.
	# Do not call enable_dhcp during this window or we race the recreate.
	sleep 15;
	
	if ($self->wait_for_ssh(45, 5)) {
		for my $attempt (1 .. 6) {
			last if $self->file_exists($done_path, 0);
			notify($ERRORS{'DEBUG'}, 0, "waiting for $done_path on $computer_name (attempt $attempt/6)");
			sleep 2;
		}
		my ($log_exit, $log_output) = $self->execute("cat $log_path", 0);
		if (defined($log_output) && @$log_output) {
			notify($ERRORS{'OK'}, 0, "vmk generalize log on $computer_name:\n" . join("\n", @$log_output));
			if (grep(/VCL_ESXI_PRECAPTURE: failed to re-add/, @$log_output)) {
				notify($ERRORS{'WARNING'}, 0, "detached generalize script failed to re-add $interface_name on $computer_name");
				return;
			}
		}
		delete $self->{network_configuration};
		delete $self->{private_interface_name};
		notify($ERRORS{'OK'}, 0, "SSH returned after $interface_name recreate on $computer_name");
		return 1;
	}
	
	notify($ERRORS{'OK'}, 0, "SSH did not return after $interface_name recreate on $computer_name (DHCP may have issued a different address); guest script set DHCP and auto-backup, shutdown will use provisioner power_off if needed");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _bootstrap_nested_management_network

 Parameters  : none
 Returns     : boolean
 Description : After nested ESXi powerOn and before wait_for_ssh, uses VMware
               Guest Operations (Tools channel — no guest SSH) to:
                 1. wait until toolsRunning
                 2. install the management node's SSH public key at
                    /etc/ssh/keys-root/authorized_keys
                 3. enable TSM-SSH / sshServer
                 4. recreate vmk0 with the VCL-assigned computer IP if the
                    baked-in golden-image address does not already match
               Idempotent: if vmk0 already has the intended IP, the interface
               is not destroyed. Non-VMware provisioners (e.g. libvirt/KVM)
               skip this path.

=cut

sub _bootstrap_nested_management_network {
	my $self = shift;
	if (ref($self) !~ /VCL::Module/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	my $computer_name = $self->data->get_computer_short_name() || '';
	my $reservation_id = $self->data->get_reservation_id();
	my $computer_id = $self->data->get_computer_id();
	
	my $provisioner = $self->provisioner(0);
	if (!$provisioner || ref($provisioner) !~ /VMware/i) {
		notify($ERRORS{'DEBUG'}, 0, "skipping nested ESXi guestOps bootstrap on $computer_name, provisioner is not VMware: " . (ref($provisioner) || 'undef'));
		return 1;
	}
	
	my $api = eval { $provisioner->api };
	if (!$api || !$api->can('wait_for_guest_tools') || !$api->can('guest_run_script')) {
		notify($ERRORS{'WARNING'}, 0, "nested ESXi guestOps bootstrap unavailable on $computer_name, VMware API does not implement wait_for_guest_tools/guest_run_script (" . (ref($api) || 'undef') . ")");
		return;
	}
	
	notify($ERRORS{'OK'}, 0, "starting nested ESXi management-network bootstrap on $computer_name via " . ref($api) . " guest operations (no guest SSH)");
	insertloadlog($reservation_id, $computer_id, "info", "nested ESXi guestOps bootstrap starting on $computer_name") if $reservation_id && $computer_id;
	
	my $tools_info = $api->wait_for_guest_tools(480);
	if (!$tools_info) {
		notify($ERRORS{'WARNING'}, 0, "VMware Tools did not become ready on $computer_name; cannot reconfigure vmk0 without guest operations");
		insertloadlog($reservation_id, $computer_id, "info", "nested ESXi guestOps bootstrap failed: tools not ready") if $reservation_id && $computer_id;
		return;
	}
	
	my $guest_reported_ip = $tools_info->{ip_address} || '';
	notify($ERRORS{'OK'}, 0, "VMware Tools ready on $computer_name, guest-reported IP: " . ($guest_reported_ip || '<none>'));
	
	my $intended = $self->_nested_esxi_intended_vmk0();
	if (!$intended || !$intended->{ip_address}) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine VCL-assigned IP for $computer_name; skipping vmk0 rewrite (SSH keys will still be attempted)");
	}
	else {
		notify($ERRORS{'OK'}, 0, "intended nested ESXi vmk0 on $computer_name: $intended->{ip_address}/$intended->{netmask} gw=" . ($intended->{gateway} || '<none>') . " (source: $intended->{source})" . ($guest_reported_ip ? ", guest currently reports $guest_reported_ip" : ''));
	}
	
	my @guest_passwords = $self->_nested_esxi_guest_passwords();
	if (!@guest_passwords) {
		notify($ERRORS{'WARNING'}, 0, "no guest root password candidates for $computer_name (set windows_root_password in vcld.conf or ESXI_GUEST_ROOT_PASSWORD)");
		return;
	}
	
	my $auth_password;
	for my $index (0 .. $#guest_passwords) {
		my $candidate = $guest_passwords[$index];
		notify($ERRORS{'DEBUG'}, 0, "trying nested ESXi guestOps authentication as root (candidate " . ($index + 1) . "/" . scalar(@guest_passwords) . ")");
		my $probe = $api->guest_run_script("echo VCL_GUEST_AUTH_OK; uname -a; localcli system version get >/dev/null 2>&1; echo VCL_LOCALCLI_RC=\$?\n", 'root', $candidate, 60);
		if ($probe && $probe->{ok} && defined($probe->{output}) && $probe->{output} =~ /VCL_GUEST_AUTH_OK/) {
			$auth_password = $candidate;
			notify($ERRORS{'OK'}, 0, "nested ESXi guestOps authenticated as root on $computer_name (candidate " . ($index + 1) . ")");
			last;
		}
		my $err = $probe ? ($probe->{output} || 'auth failed') : 'guest_run_script returned undef';
		notify($ERRORS{'DEBUG'}, 0, "guestOps auth candidate " . ($index + 1) . " failed: $err");
	}
	if (!$auth_password) {
		notify($ERRORS{'WARNING'}, 0, "failed to authenticate GuestOperationsManager as root on $computer_name; cannot rewrite vmk0 or install SSH keys");
		insertloadlog($reservation_id, $computer_id, "info", "nested ESXi guestOps bootstrap failed: guest auth") if $reservation_id && $computer_id;
		return;
	}
	
	my $pubkey = $self->_nested_esxi_management_node_pubkey();
	if ($pubkey) {
		if ($api->can('guest_write_file')) {
			if (!$api->guest_write_file('/tmp/vcl-root.pub', $pubkey, 'root', $auth_password)) {
				notify($ERRORS{'WARNING'}, 0, "failed to upload MN public key via guest file transfer, bootstrap script will skip key install if /tmp/vcl-root.pub is missing");
			}
			else {
				notify($ERRORS{'DEBUG'}, 0, "uploaded management node public key to $computer_name:/tmp/vcl-root.pub");
			}
		}
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "management node SSH public key could not be read; guest authorized_keys will not be updated");
	}
	
	my $script = $self->_nested_esxi_bootstrap_script($intended);
	my $result = $api->guest_run_script($script, 'root', $auth_password, 180);
	if (!$result || !$result->{ok}) {
		notify($ERRORS{'WARNING'}, 0, "nested ESXi bootstrap script failed on $computer_name: " . ($result ? $result->{output} : 'undef'));
		insertloadlog($reservation_id, $computer_id, "info", "nested ESXi guestOps bootstrap script failed") if $reservation_id && $computer_id;
		return;
	}
	
	my $output = $result->{output} || '';
	notify($ERRORS{'OK'}, 0, "nested ESXi bootstrap script finished on $computer_name:\n$output");
	
	if ($output =~ /VCL_ESXI_BOOTSTRAP: vmk0 already matches/) {
		insertloadlog($reservation_id, $computer_id, "info", "nested ESXi vmk0 already matched intended IP") if $reservation_id && $computer_id;
	}
	elsif ($output =~ /VCL_ESXI_BOOTSTRAP: recreating vmk0/) {
		insertloadlog($reservation_id, $computer_id, "staticIPaddress", "nested ESXi vmk0 reconfigured to " . ($intended->{ip_address} || 'unknown')) if $reservation_id && $computer_id;
	}
	else {
		insertloadlog($reservation_id, $computer_id, "info", "nested ESXi guestOps bootstrap completed") if $reservation_id && $computer_id;
	}
	
	if ($output =~ /VCL_ESXI_BOOTSTRAP: (failed|error)/i) {
		notify($ERRORS{'WARNING'}, 0, "bootstrap script reported a failure on $computer_name");
		return;
	}
	
	notify($ERRORS{'OK'}, 0, "nested ESXi management-network bootstrap succeeded on $computer_name");
	return 1;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _nested_esxi_intended_vmk0

 Parameters  : none
 Returns     : hashref {ip_address, netmask, gateway, source} or undef
 Description : Selects the IPv4 address VCL will wait on over SSH.
               wait_for_ssh uses computer_node_name -> privateIPaddress (then
               DNS). computer.IPaddress is the public address
               (get_computer_public_ip_address). Nested ESXi has a single vmk0
               on one LAN, so private IP is preferred when set, else public.

=cut

sub _nested_esxi_intended_vmk0 {
	my $self = shift;
	
	my $private_ip = eval { $self->data->get_computer_private_ip_address(0) } || '';
	my $public_ip = eval { $self->data->get_computer_public_ip_address(0) } || '';
	
	my $ip_address;
	my $source;
	if ($private_ip && $private_ip =~ /^\d+\.\d+\.\d+\.\d+$/) {
		$ip_address = $private_ip;
		$source = 'computer.privateIPaddress';
		if ($public_ip && $public_ip ne $private_ip) {
			notify($ERRORS{'DEBUG'}, 0, "computer.IPaddress ($public_ip) differs from privateIPaddress ($private_ip); using private IP because wait_for_ssh targets it");
		}
	}
	elsif ($public_ip && $public_ip =~ /^\d+\.\d+\.\d+\.\d+$/) {
		$ip_address = $public_ip;
		$source = 'computer.IPaddress';
	}
	
	if (!$ip_address) {
		return;
	}
	
	my $netmask = eval { $self->data->get_management_node_public_subnet_mask() } || '';
	$netmask = '255.255.255.0' if !$netmask || $netmask !~ /^\d+\.\d+\.\d+\.\d+$/;
	
	my $gateway = eval { $self->data->get_nathost_internal_ip_address(0) } || '';
	if (!$gateway) {
		$gateway = eval { $self->data->get_management_node_public_default_gateway() } || '';
	}
	$gateway = '' if $gateway && $gateway !~ /^\d+\.\d+\.\d+\.\d+$/;
	
	return {
		ip_address => $ip_address,
		netmask => $netmask,
		gateway => $gateway,
		source => $source,
	};
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _nested_esxi_guest_passwords

 Parameters  : none
 Returns     : list of password strings
 Description : GuestOperationsManager needs the nested ESXi root password (not
               the metal host password). Candidates, first match wins:
                 ESXI_GUEST_ROOT_PASSWORD in vcld.conf
                 windows_root_password (WINDOWS_ROOT_PASSWORD) — set on the
                   image during ESXi.pm::pre_capture
                 vmprofile.password (often reused in lab images)

=cut

sub _nested_esxi_guest_passwords {
	my $self = shift;
	my @passwords;
	my %seen;
	
	my $vcld_config = $self->local_read_vcld_config("/etc/vcl/vcld.conf");
	if ($vcld_config && $vcld_config->{ESXI_GUEST_ROOT_PASSWORD}) {
		push @passwords, $vcld_config->{ESXI_GUEST_ROOT_PASSWORD};
	}
	if ($WINDOWS_ROOT_PASSWORD) {
		push @passwords, $WINDOWS_ROOT_PASSWORD;
	}
	my $vmhost_password = eval { $self->data->get_vmhost_profile_password(0) } || '';
	push @passwords, $vmhost_password if $vmhost_password;
	
	my @unique;
	for my $password (@passwords) {
		next if !defined($password) || !length($password);
		next if $seen{$password}++;
		push @unique, $password;
	}
	return @unique;
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _nested_esxi_management_node_pubkey

 Parameters  : none
 Returns     : string (one or more authorized_keys lines) or undef
 Description : Reads the management node's SSH public key(s) from the identity
               key paths used by wait_for_ssh / execute.

=cut

sub _nested_esxi_management_node_pubkey {
	my $self = shift;
	
	my @key_paths;
	eval { @key_paths = VCL::DataStructure::get_management_node_identity_key_paths(); };
	if (!@key_paths) {
		@key_paths = ('/etc/vcl/vcl.key');
	}
	
	my @pubkeys;
	for my $private_path (@key_paths) {
		my $pub_path = $private_path;
		$pub_path .= '.pub' unless $pub_path =~ /\.pub$/;
		if (-r $pub_path) {
			if (open(my $fh, '<', $pub_path)) {
				while (my $line = <$fh>) {
					chomp $line;
					push @pubkeys, $line if $line =~ /^\s*ssh-\S+\s+\S+/;
				}
				close $fh;
			}
			next;
		}
		if (-r $private_path) {
			my $quoted = $private_path;
			$quoted =~ s/'/'\\''/g;
			my ($exit_status, $output) = run_command("ssh-keygen -y -f '$quoted'", 1, 15);
			if (defined($output) && grep(/ssh-\S+/, @$output)) {
				for my $line (@$output) {
					push @pubkeys, $line if $line =~ /^\s*ssh-\S+\s+\S+/;
				}
			}
		}
	}
	
	if (!@pubkeys && -r '/root/.ssh/id_rsa.pub') {
		if (open(my $fh, '<', '/root/.ssh/id_rsa.pub')) {
			while (my $line = <$fh>) {
				chomp $line;
				push @pubkeys, $line if $line =~ /^\s*ssh-\S+\s+\S+/;
			}
			close $fh;
		}
	}
	
	if (!@pubkeys) {
		notify($ERRORS{'WARNING'}, 0, "no management node SSH public keys found (tried identity paths and /root/.ssh/id_rsa.pub)");
		return;
	}
	
	my %seen;
	my @unique;
	for my $key (@pubkeys) {
		next if $seen{$key}++;
		push @unique, $key;
	}
	notify($ERRORS{'DEBUG'}, 0, "loaded " . scalar(@unique) . " management node SSH public key(s) for nested ESXi authorized_keys");
	return join("\n", @unique) . "\n";
}

#//////////////////////////////////////////////////////////////////////////////

=head2 _nested_esxi_bootstrap_script

 Parameters  : $intended hashref (optional)
 Returns     : shell script string (BusyBox ash)
 Description : Guest-side script: install SSH keys, enable TSM-SSH, and
               recreate vmk0 (Instant Clone style) when the current address
               does not match the VCL-assigned IP.

=cut

sub _nested_esxi_bootstrap_script {
	my $self = shift;
	my $intended = shift || {};
	
	my $ip = $intended->{ip_address} || '';
	my $netmask = $intended->{netmask} || '255.255.255.0';
	my $gateway = $intended->{gateway} || '';
	
	# Values are interpolated into a single-quoted ash script via printf-style
	# wrapping below; strip anything that is not an IP/mask token.
	$ip =~ s/[^0-9.]//g;
	$netmask =~ s/[^0-9.]//g;
	$gateway =~ s/[^0-9.]//g;
	
	return <<'SCRIPT_TOP' . <<"SCRIPT_VARS" . <<'SCRIPT_BODY';
#!/bin/sh
# VCL nested ESXi bootstrap — runs via GuestOperations, not SSH.
log() { echo "VCL_ESXI_BOOTSTRAP: $*"; }
uname_s=$(uname -a 2>/dev/null)
log "begin $uname_s"
SCRIPT_TOP
INTENDED_IP='$ip'
NETMASK='$netmask'
GATEWAY='$gateway'
SCRIPT_VARS
PUBKEY_FILE=/tmp/vcl-root.pub
AUTH_KEYS=/etc/ssh/keys-root/authorized_keys

# --- SSH authorized_keys (ESXi persist path) ---
if [ -f "$PUBKEY_FILE" ]; then
	mkdir -p /etc/ssh/keys-root
	touch "$AUTH_KEYS"
	while IFS= read -r key
	do
		[ -z "$key" ] && continue
		if grep -F "$key" "$AUTH_KEYS" >/dev/null 2>&1; then
			log "authorized_keys already contains MN key"
		else
			echo "$key" >> "$AUTH_KEYS"
			log "appended MN key to $AUTH_KEYS"
		fi
	done < "$PUBKEY_FILE"
	chmod 600 "$AUTH_KEYS" 2>/dev/null || true
else
	log "no $PUBKEY_FILE uploaded, skipping authorized_keys"
fi

# sshd AllowUsers: kickstart --key= may leave root off the list
if [ -f /etc/ssh/sshd_config ] && grep '^AllowUsers' /etc/ssh/sshd_config >/dev/null 2>&1; then
	if grep '^AllowUsers' /etc/ssh/sshd_config | grep root >/dev/null 2>&1; then
		log "sshd AllowUsers already includes root"
	else
		sed -i -e 's/^AllowUsers /AllowUsers root /' /etc/ssh/sshd_config
		log "added root to sshd AllowUsers"
	fi
fi

vim-cmd hostsvc/enable_ssh >/dev/null 2>&1 || true
vim-cmd hostsvc/start_ssh >/dev/null 2>&1 || true
localcli network firewall ruleset set --ruleset-id=sshServer --enabled true >/dev/null 2>&1 || true
localcli network firewall ruleset set --ruleset-id=sshServer --allowed-all true >/dev/null 2>&1 || true
log "enabled TSM-SSH and sshServer firewall ruleset"

# --- vmk0 ---
current_ip=""
current_line=$(localcli network ip interface ipv4 get 2>/dev/null | awk '/^vmk0[ \t]/ {print; exit}')
if [ -n "$current_line" ]; then
	current_ip=$(echo "$current_line" | awk '{print $2}')
fi
log "current vmk0 ipv4=$current_ip intended=$INTENDED_IP"

if [ -z "$INTENDED_IP" ]; then
	log "no intended IP supplied, skipping vmk0 reconfigure"
	localcli network ip interface ipv4 get 2>/dev/null || true
	exit 0
fi

if [ "$current_ip" = "$INTENDED_IP" ]; then
	log "vmk0 already matches intended IP, skipping reconfigure"
	localcli network ip interface ipv4 get 2>/dev/null || true
	exit 0
fi

pg=""
pg=$(localcli network ip interface list 2>/dev/null | awk '
	$0 ~ /^vmk0[[:space:]]*$/ {inblk=1; next}
	$0 ~ /Name:[[:space:]]*vmk0/ {inblk=1; next}
	inblk && /Port[ ]*[Gg]roup:/ {
		sub(/^.*Port[ ]*[Gg]roup:[[:space:]]*/, "")
		print
		exit
	}
	inblk && /^vmk[0-9]/ {exit}
')
pg=$(echo "$pg" | sed 's/[[:space:]]*$//')
if [ -z "$pg" ]; then
	pg="Management Network"
	log "portgroup not parsed, defaulting to Management Network"
else
	log "vmk0 portgroup=$pg"
fi

log "recreating vmk0 (Instant Clone style) pg=$pg ip=$INTENDED_IP mask=$NETMASK gw=$GATEWAY"
localcli network ip interface set -e false -i vmk0 || true
localcli network ip interface remove -i vmk0 || true

if ! localcli network ip interface add -i vmk0 -p "$pg"; then
	log "add with parsed portgroup failed, trying Management Network then VM Network"
	localcli network ip interface add -i vmk0 -p "Management Network" || localcli network ip interface add -i vmk0 -p "VM Network" || {
		log "failed to re-add vmk0"
		exit 1
	}
fi

if [ -n "$NETMASK" ]; then
	if localcli network ip interface ipv4 set -i vmk0 -I "$INTENDED_IP" -N "$NETMASK" -t static; then
		log "set vmk0 static $INTENDED_IP/$NETMASK"
	else
		log "failed to set static IPv4 on vmk0"
		exit 1
	fi
else
	localcli network ip interface ipv4 set -i vmk0 -t dhcp
	log "set vmk0 dhcp"
fi

if [ -n "$GATEWAY" ]; then
	localcli network ip route ipv4 add -g "$GATEWAY" -n default >/dev/null 2>&1 || log "default route add skipped or already present"
fi

log "final ipv4:"
localcli network ip interface ipv4 get 2>/dev/null || true
exit 0
SCRIPT_BODY
}

1;
__END__


#//////////////////////////////////////////////////////////////////////////////

=head2 get_os_type

 Parameters  : none
 Returns     : string
 Description : Returns the OS type of the guest. ESXi 'uname -a' reports
               'VMkernel ... ESXi' which the base OS.pm::get_os_type() does
               not recognize (no 'linux'/'win' substring). The OS table row
               'vmwareesxi' has type 'linux', so return 'linux' for ESXi
               guests so that libvirt.pm::get_active_domain_name() works.

=cut



#//////////////////////////////////////////////////////////////////////////////

=head2 get_private_mac_address

 Parameters  : none
 Returns     : string
 Description : Returns the MAC address of the first VMkernel NIC (esxcli).

=cut


#//////////////////////////////////////////////////////////////////////////////

=head2 get_public_mac_address

 Parameters  : none
 Returns     : string
 Description : ESXi nested suele tener un solo VMkernel NIC (vmk0) para todo.
               Devuelve la misma MAC que private.

=cut


=head1 SEE ALSO

L<http://cwiki.apache.org/VCL/>

=cut
