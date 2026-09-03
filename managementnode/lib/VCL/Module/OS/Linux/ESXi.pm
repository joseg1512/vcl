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
 enable_dhcp + ifcfg-* / route-*    esxcli network ip interface ipv4 set --type=dhcp
 /etc/sysconfig/network HOSTNAME    esxcli system hostname (cleared to image default)
 shutdown -h now                    esxcli system shutdown poweroff
 provisioner capture                Unchanged: VMware.pm copies/renames vmdk
 OS::post_capture stage scripts     Same (management node)

 post_load:
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
               NFS datastores, VCL accounts, root password, DHCP on
               VMkernel NICs, power off.

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
	
	my $private_interface_name = $self->get_private_interface_name();
	my $public_interface_name = $self->get_public_interface_name();
	
	if ($private_interface_name && !$self->enable_dhcp($private_interface_name)) {
		notify($ERRORS{'WARNING'}, 0, "failed to enable DHCP on the private VMkernel interface");
		return;
	}
	if ($public_interface_name && $public_interface_name ne ($private_interface_name || '') && !$self->enable_dhcp($public_interface_name)) {
		notify($ERRORS{'WARNING'}, 0, "failed to enable DHCP on the public VMkernel interface");
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
               ext_sshd, rdate, /etc/sysconfig). Waits for SSH, writes
               currentimage.txt, confirms VMkernel NICs, updates public IP,
               syncs time, sets root password, hostname, then OS.pm post_load.

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
		elsif ($exit_status && $exit_status ne '0' && !grep(/already/i, @$output)) {
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

1;
__END__

=head1 SEE ALSO

L<http://cwiki.apache.org/VCL/>

=cut
