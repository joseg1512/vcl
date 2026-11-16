#!/usr/bin/perl
###############################################################################
# Unit test for the Ubuntu specific paths of
# VCL::Module::OS::Linux::firewall::iptables
#
# Ubuntu cannot be installed in the lab where this branch is being tested, so
# the two decisions that only differ on Ubuntu are covered here with stubs:
#
#   * _disable_distribution_firewall: nothing is executed when systemctl is not
#     available, and ufw / firewalld are disabled when they are active.
#   * save_configuration without an argument: /etc/sysconfig/iptables on Red Hat
#     (/etc/sysconfig exists) and /var/lib/vcl/iptables.save on Ubuntu.
#
# No management node and no database are needed: the data and os objects are
# replaced by small fakes. VCL::utils parses a vcld configuration file in its
# INIT block (by default /etc/vcl/vcld.conf, which only root can read), so a
# throwaway configuration file is created and passed with -config before the
# module is loaded.
###############################################################################
use strict;
use warnings;

use FindBin;
use File::Temp qw(tempfile);

# Kept in scope for the whole process so File::Temp can remove the file on exit
our $config_fh;

BEGIN {
	# The configuration file has to exist before VCL::utils runs its INIT block,
	# which is before any code outside a BEGIN block executes.
	my ($fh, $conf) = tempfile('vcl-fw-test-ubuntu-XXXXXX', UNLINK => 1);
	print $fh "FQDN=test.example.org\n";
	$fh->flush;
	$config_fh = $fh;
	@ARGV = ("-config=$conf");
}

use lib "$FindBin::Bin/../../lib";
use VCL::Module::OS::Linux::firewall::iptables;

no warnings 'redefine';
*VCL::Module::OS::Linux::firewall::iptables::notify = sub { return 1; };

package FakeOS;
sub new {
	my ($class, %args) = @_;
	return bless {
		command_exists => $args{command_exists},
		file_exists    => ($args{file_exists} || {}),
		services       => ($args{services} || {}),
		commands       => [],
		files_written  => [],
	}, $class;
}

sub command_exists {
	my $self = shift;
	return $self->{command_exists};
}

sub file_exists {
	my ($self, $path) = @_;
	return ($self->{file_exists}->{$path} ? 1 : 0);
}

sub execute {
	my ($self, $command) = @_;
	push(@{$self->{commands}}, $command);
	
	# systemctl is-active <service>
	if ($command =~ /^systemctl is-active (\S+)$/) {
		my $service_name = $1;
		return (0, [($self->{services}->{$service_name} || 'inactive') . "\n"]);
	}
	
	# systemctl disable --now <service>: the service ends up inactive
	if ($command =~ /^systemctl disable --now (\S+)$/) {
		$self->{services}->{$1} = 'inactive';
		return (0, ['']);
	}
	
	if ($command =~ m{^/sbin/iptables-save$}) {
		return (0, ['*filter', '-A INPUT -j vcl-post_load', 'COMMIT']);
	}
	
	return (0, ['']);
}

sub create_text_file {
	my ($self, $file_path, $content) = @_;
	push(@{$self->{files_written}}, $file_path);
	return 1;
}

package FakeData;
sub new { return bless {}, shift }
sub get_computer_short_name { return 'fwtubuntu-vm' }
sub get_computer_hostname { return 'fwtubuntu-vm.example.org' }
sub get_computer_id { return 1234 }

package main;
my $failures = 0;
sub check {
	my ($name, $ok, $detail) = @_;
	$failures++ if !$ok;
	printf "%s %-62s %s\n", ($ok ? 'OK  ' : 'FAIL'), $name, (defined($detail) ? $detail : '');
}

sub new_object {
	my $fake_os = FakeOS->new(@_);
	my $fake_data = FakeData->new();
	my $object = bless { data_structure => $fake_data, data => $fake_data, os => $fake_os },
		'VCL::Module::OS::Linux::firewall::iptables';
	return ($object, $fake_os);
}

# 1) No systemctl: nothing is executed and the subroutine succeeds
{
	my ($object, $fake_os) = new_object(command_exists => 0);
	my $result = $object->_disable_distribution_firewall();
	check('sin systemctl: no se ejecuta nada', (!@{$fake_os->{commands}} && $result == 1),
		'comandos=' . scalar(@{$fake_os->{commands}}) . " resultado=$result");
}

# 2) systemctl available, both distribution firewalls active: both are disabled
{
	my ($object, $fake_os) = new_object(
		command_exists => 1,
		services       => { 'ufw' => 'active', 'firewalld' => 'active' },
	);
	my $result = $object->_disable_distribution_firewall();
	my $commands = join(' | ', @{$fake_os->{commands}});
	my $ufw_disabled = (grep { $_ eq 'systemctl disable --now ufw' } @{$fake_os->{commands}}) ? 1 : 0;
	my $firewalld_disabled = (grep { $_ eq 'systemctl disable --now firewalld' } @{$fake_os->{commands}}) ? 1 : 0;
	check('con systemctl y ufw/firewalld activos: se desactivan los dos',
		($result == 1 && $ufw_disabled && $firewalld_disabled), $commands);
}

# 3) Ubuntu: no /etc/sysconfig, the configuration is saved to /var/lib/vcl
{
	my ($object, $fake_os) = new_object(command_exists => 1, file_exists => {});
	$object->save_configuration();
	my $file_path = $fake_os->{files_written}->[0];
	my $created_directory = (grep { $_ eq 'mkdir -p /var/lib/vcl' } @{$fake_os->{commands}}) ? 1 : 0;
	check('sin /etc/sysconfig: se guarda en /var/lib/vcl/iptables.save',
		(scalar(@{$fake_os->{files_written}}) == 1 && $file_path eq '/var/lib/vcl/iptables.save' && $created_directory),
		'archivo=' . (defined($file_path) ? $file_path : '<ninguno>'));
}

# 4) Red Hat: /etc/sysconfig exists, the configuration is saved to /etc/sysconfig/iptables
{
	my ($object, $fake_os) = new_object(command_exists => 1, file_exists => { '/etc/sysconfig' => 1 });
	$object->save_configuration();
	my $file_path = $fake_os->{files_written}->[0];
	my $created_directory = (grep { $_ eq 'mkdir -p /var/lib/vcl' } @{$fake_os->{commands}}) ? 1 : 0;
	check('con /etc/sysconfig: se guarda en /etc/sysconfig/iptables',
		(scalar(@{$fake_os->{files_written}}) == 1 && $file_path eq '/etc/sysconfig/iptables' && !$created_directory),
		'archivo=' . (defined($file_path) ? $file_path : '<ninguno>'));
}

exit($failures ? 1 : 0);
