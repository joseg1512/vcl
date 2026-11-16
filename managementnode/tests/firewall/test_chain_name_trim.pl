#!/usr/bin/perl
###############################################################################
# Unit test: get_table_info/get_table_chain_names devuelven nombres de cadena
# sin salto de linea aunque _execute_iptables entregue lineas con \n final.
###############################################################################
use strict;
use warnings;

use FindBin;
use File::Temp qw(tempfile);

our $config_fh;
BEGIN {
	my ($fh, $conf) = tempfile('vcl-fw-test-chain-trim-XXXXXX', UNLINK => 1);
	print $fh "FQDN=test.example.org\n";
	$fh->flush;
	$config_fh = $fh;
	@ARGV = ("-config=$conf");
}

use lib "$FindBin::Bin/../../lib";
use VCL::Module::OS::Linux::firewall::iptables;

no warnings 'redefine';
no warnings 'once';
*VCL::Module::OS::Linux::firewall::iptables::notify = sub { return 1; };
*VCL::Module::OS::Linux::firewall::iptables::get_all_direct_rules = sub { return; };

# Devuelve lineas CON \n al final, como si execute no las hubiera recortado
*VCL::Module::OS::Linux::firewall::iptables::_execute_iptables = sub {
	my ($self, $command) = @_;
	return (0, ["-P INPUT ACCEPT\n", "-P FORWARD ACCEPT\n", "-P OUTPUT ACCEPT\n",
		"-N vcl-reserved\n", "-A vcl-reserved -j ACCEPT\n"]);
};

package FakeData;
sub new { return bless {}, shift }
sub get_computer_hostname { return 'fwtest-vm' }
sub get_computer_short_name { return 'fwtest-vm' }

package main;
my $fake_data = FakeData->new();
my $object = bless { data_structure => $fake_data, data => $fake_data }, 'VCL::Module::OS::Linux::firewall::iptables';

my $failures = 0;

my $table_info = $object->get_table_info('filter');
if (!defined($table_info)) {
	print "FAIL get_table_info devolvio undef\n";
	$failures++;
}
elsif (exists($table_info->{'vcl-reserved'})) {
	print "OK  get_table_info: clave 'vcl-reserved' limpia\n";
}
elsif (exists($table_info->{"vcl-reserved\n"})) {
	print "FAIL get_table_info: la clave tiene \\n final\n";
	$failures++;
}
else {
	print "FAIL get_table_info: no se encontro la cadena vcl-reserved\n";
	$failures++;
}

my @chain_names = $object->get_table_chain_names('filter');
my $clean = grep { $_ eq 'vcl-reserved' } @chain_names;
my $dirty = grep { $_ eq "vcl-reserved\n" } @chain_names;
if ($clean && !$dirty) {
	print "OK  get_table_chain_names: 'vcl-reserved' sin \\n\n";
}
else {
	print "FAIL get_table_chain_names: nombres=" . join(',', map { "'$_'" } @chain_names) . "\n";
	$failures++;
}

exit($failures ? 1 : 0);
