#!/usr/bin/perl
###############################################################################
# Unit test for VCL::Module::OS::Linux::firewall::iptables::get_allowed_source
#
# No management node and no database are needed: the data and os objects are
# replaced by small fakes and the firewall_connect_* globals are set per case.
#
# VCL::utils parses a vcld configuration file in its INIT block (by default
# /etc/vcl/vcld.conf, which only root can read), so a throwaway configuration
# file is created and passed with -config before the module is loaded.
#
# notify is replaced by a stub that records the messages instead of printing
# them, so the fallbacks can be checked for their WARNING and the normal cases
# for the absence of one.
###############################################################################
use strict;
use warnings;

use FindBin;
use File::Temp qw(tempfile);

# Kept in scope for the whole process so File::Temp can remove the file on exit
our $config_fh;

BEGIN {
	# The configuration file has to exist before VCL::utils runs its INIT block,
	# which is before any code outside a BEGIN block executes. The handle is
	# kept open in a package variable because with UNLINK => 1 File::Temp
	# deletes the file as soon as the handle is closed.
	my ($fh, $conf) = tempfile('vcl-fw-test-allowed-source-XXXXXX', UNLINK => 1);
	print $fh "FQDN=test.example.org\n";
	$fh->flush;
	$config_fh = $fh;
	@ARGV = ("-config=$conf");
}

use lib "$FindBin::Bin/../../lib";
use VCL::Module::OS::Linux::firewall::iptables;

our @notifications;
no warnings 'redefine';
*VCL::Module::OS::Linux::firewall::iptables::notify = sub { push(@notifications, $_[2]); return 1; };

package FakeData;
sub new { return bless {}, shift }
sub get_reservation_remote_ip { return '203.0.113.9' }
sub get_computer_short_name { return 'fwtest-vm' }

package main;
my $fake_data = FakeData->new();
my $object = bless { data_structure => $fake_data, data => $fake_data }, 'VCL::Module::OS::Linux::firewall::iptables';

my @cases = (
	# modo,    rango,           etapa,      remote IP,      esperado,       warnings
	[ undef,   undef,           'reserved', undef,          undef,          0 ],
	[ 'normal', undef,          'reserved', undef,          undef,          0 ],
	[ 'normal', undef,          'inuse',    '203.0.113.9',  '203.0.113.9',  0 ],
	[ 'normal', undef,          'inuse',    undef,          undef,          0 ],
	[ 'range', '10.0.0.0/8',    'reserved', undef,          '10.0.0.0/8',   0 ],
	[ 'range', '10.0.0.0/8',    'inuse',    '203.0.113.9',  '10.0.0.0/8',   0 ],
	[ 'range', '0.0.0.0',       'inuse',    undef,          '0.0.0.0/0',    0 ],
	[ 'range', '10.0.0.7',      'inuse',    undef,          '10.0.0.7/32',  0 ],
	# Rechazos del rango: se cae a normal y se usa la IP del Connect
	[ 'range', undef,           'inuse',    '203.0.113.9',  '203.0.113.9',  1 ],
	[ 'range', 'no-es-cidr',    'inuse',    '203.0.113.9',  '203.0.113.9',  1 ],
	[ 'range', 'fd00::/8',      'inuse',    '203.0.113.9',  '203.0.113.9',  1 ],
	[ 'range', '10.0.0.0/33',   'inuse',    '203.0.113.9',  '203.0.113.9',  1 ],
	[ 'range', '300.0.0.1',     'inuse',    '203.0.113.9',  '203.0.113.9',  1 ],
	# Modo desconocido y etapa desconocida
	[ 'otro',  undef,           'inuse',    '203.0.113.9',  '203.0.113.9',  1 ],
	[ 'normal', undef,          'otra',     '203.0.113.9',  undef,          1 ],
);

my $failures = 0;
for my $case (@cases) {
	my ($mode, $range, $stage, $remote_ip, $expected, $expected_warnings) = @$case;
	$VCL::utils::FIREWALL_CONNECT_MODE = $mode;
	$VCL::utils::FIREWALL_CONNECT_RANGE = $range;
	@notifications = ();
	my $got = $object->get_allowed_source($stage, $remote_ip);
	my $ok = (!defined($expected) && !defined($got)) || (defined($expected) && defined($got) && $got eq $expected);
	my $warning_count = scalar(@notifications);
	$ok = 0 if ($warning_count != $expected_warnings);
	$failures++ if !$ok;
	printf "%s mode=%-6s range=%-12s stage=%-8s -> %-12s warnings=%d\n", ($ok ? 'OK  ' : 'FAIL'),
		(defined($mode) ? $mode : '-'), (defined($range) ? $range : '-'), $stage,
		(defined($got) ? $got : 'undef'), $warning_count;
}

exit($failures ? 1 : 0);
