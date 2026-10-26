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
###############################################################################
use strict;
use warnings;

BEGIN {
	my $conf = "/tmp/vcl-fw-test-allowed-source.conf";
	open(my $fh, '>', $conf) or die "failed to create $conf: $!";
	print $fh "FQDN=test.example.org\n";
	close($fh);
	@ARGV = ("-config=$conf");
}

use FindBin;
use lib "$FindBin::Bin/../../lib";
use VCL::Module::OS::Linux::firewall::iptables;

no warnings 'redefine';
*VCL::Module::OS::Linux::firewall::iptables::notify = sub { return 1; };

package FakeData;
sub new { return bless {}, shift }
sub get_reservation_remote_ip { return '203.0.113.9' }
sub get_computer_short_name { return 'fwtest-vm' }

package main;
my $fake_data = FakeData->new();
my $object = bless { data_structure => $fake_data, data => $fake_data }, 'VCL::Module::OS::Linux::firewall::iptables';

my @cases = (
	# modo,    rango,           etapa,      remote IP,      esperado
	[ undef,   undef,           'reserved', undef,          undef ],
	[ 'normal', undef,          'reserved', undef,          undef ],
	[ 'normal', undef,          'inuse',    '203.0.113.9',  '203.0.113.9' ],
	[ 'normal', undef,          'inuse',    undef,          undef ],
	[ 'range', '10.0.0.0/8',    'reserved', undef,          '10.0.0.0/8' ],
	[ 'range', '10.0.0.0/8',    'inuse',    '203.0.113.9',  '10.0.0.0/8' ],
	[ 'range', '0.0.0.0',       'inuse',    undef,          '0.0.0.0/0' ],
	[ 'range', '10.0.0.7',      'inuse',    undef,          '10.0.0.7/32' ],
	[ 'range', undef,           'inuse',    '203.0.113.9',  '203.0.113.9' ],
	[ 'range', 'no-es-cidr',    'inuse',    '203.0.113.9',  '203.0.113.9' ],
	[ 'otro',  undef,           'inuse',    '203.0.113.9',  '203.0.113.9' ],
);

my $failures = 0;
for my $case (@cases) {
	my ($mode, $range, $stage, $remote_ip, $expected) = @$case;
	$VCL::utils::FIREWALL_CONNECT_MODE = $mode;
	$VCL::utils::FIREWALL_CONNECT_RANGE = $range;
	my $got = $object->get_allowed_source($stage, $remote_ip);
	my $ok = (!defined($expected) && !defined($got)) || (defined($expected) && defined($got) && $got eq $expected);
	$failures++ if !$ok;
	printf "%s mode=%-6s range=%-12s stage=%-8s -> %s\n", ($ok ? 'OK  ' : 'FAIL'),
		(defined($mode) ? $mode : '-'), (defined($range) ? $range : '-'), $stage,
		(defined($got) ? $got : 'undef');
}

unlink("/tmp/vcl-fw-test-allowed-source.conf");
exit($failures ? 1 : 0);
