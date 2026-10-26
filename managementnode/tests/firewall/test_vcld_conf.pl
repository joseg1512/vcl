#!/usr/bin/perl
###############################################################################
# Unit test for the firewall_connect_* globals that VCL::utils reads from
# vcld.conf.
#
# VCL::utils parses the configuration file in its INIT block (by default
# /etc/vcl/vcld.conf, which only root can read), so a throwaway configuration
# file is created and passed with -config before the module is loaded.
#
# The file is parsed once per process, so the "keys are absent" case re-runs
# this script as a child process with a different configuration.
###############################################################################
use strict;
use warnings;

use FindBin;
use File::Temp qw(tempfile);

# Kept in scope for the whole process so File::Temp can remove the files on exit
our ($config_fh, $print_keys_only);

BEGIN {
	# A throwaway configuration file has to exist before the INIT block of
	# VCL::utils runs, which is before any code outside a BEGIN block executes.
	# The handle is kept open in a package variable because with UNLINK => 1
	# File::Temp deletes the file as soon as the handle is closed.
	my $content = defined($ENV{VCL_FW_TEST_CONF_CONTENT})
		? $ENV{VCL_FW_TEST_CONF_CONTENT}
		: "FQDN=test.example.org\nFIREWALL_CONNECT_MODE=range\nFIREWALL_CONNECT_RANGE = 10.0.0.0/8\n";
	
	my ($fh, $conf) = tempfile('vcl-fw-test-vcld-XXXXXX', UNLINK => 1);
	print $fh $content;
	$fh->flush;
	$config_fh = $fh;
	
	# The child process only prints the values it read, it does not run the test
	$print_keys_only = (grep { $_ eq '--print-keys' } @ARGV) ? 1 : 0;
	@ARGV = ("-config=$conf");
}

use lib "$FindBin::Bin/../../lib";
use VCL::utils;

if ($print_keys_only) {
	printf "FIREWALL_CONNECT_MODE=%s\nFIREWALL_CONNECT_RANGE=%s\n",
		(defined($VCL::utils::FIREWALL_CONNECT_MODE) ? $VCL::utils::FIREWALL_CONNECT_MODE : '<undef>'),
		(defined($VCL::utils::FIREWALL_CONNECT_RANGE) ? $VCL::utils::FIREWALL_CONNECT_RANGE : '<undef>');
	exit(0);
}

my $failures = 0;

for my $case (
	[ 'FIREWALL_CONNECT_MODE',  'range',         $VCL::utils::FIREWALL_CONNECT_MODE ],
	[ 'FIREWALL_CONNECT_RANGE', '10.0.0.0/8',    $VCL::utils::FIREWALL_CONNECT_RANGE ],
) {
	my ($name, $expected, $got) = @$case;
	my $ok = (defined($got) && $got eq $expected);
	$failures++ if !$ok;
	printf "%s %-28s esperado=%s obtenido=%s\n", ($ok ? 'OK  ' : 'FAIL'), $name, $expected, (defined($got) ? $got : '<undef>');
}

# Un vcld.conf sin las claves: las dos quedan indefinidas y el módulo usa el
# comportamiento por defecto (modo normal).
local $ENV{VCL_FW_TEST_CONF_CONTENT} = "FQDN=test.example.org\n";

my @child_lines;
my $child_exit_status;
if (open(my $child, '-|', $^X, "$FindBin::Bin/$FindBin::Script", '--print-keys')) {
	@child_lines = <$child>;
	close($child);
	$child_exit_status = $? >> 8;
}
else {
	print "FAIL no se pudo ejecutar el subproceso: $!\n";
	$failures++;
	$child_exit_status = -1;
}
chomp(@child_lines);

my %child_values;
for my $line (@child_lines) {
	$child_values{$1} = $2 if ($line =~ /^(\w+)=(.*)$/);
}

for my $name (qw(FIREWALL_CONNECT_MODE FIREWALL_CONNECT_RANGE)) {
	my $got = $child_values{$name};
	my $ok = ($child_exit_status == 0 && defined($got) && $got eq '<undef>');
	$failures++ if !$ok;
	printf "%s %-28s esperado=<undef> obtenido=%s (sin las claves en vcld.conf, exit=%s)\n", ($ok ? 'OK  ' : 'FAIL'),
		$name, (defined($got) ? $got : '<no impreso>'), (defined($child_exit_status) ? $child_exit_status : '?');
}

exit($failures ? 1 : 0);
