#!/usr/bin/perl
use strict;
use warnings;

BEGIN {
	my $conf = "/tmp/vcl-fw-test-vcld.conf";
	open(my $fh, '>', $conf) or die $!;
	print $fh "FQDN=test.example.org\n";
	print $fh "FIREWALL_CONNECT_MODE=range\n";
	print $fh "FIREWALL_CONNECT_RANGE = 10.0.0.0/8\n";
	close($fh);
	@ARGV = ("-config=$conf");
}
use lib "$ENV{PWD}/managementnode/lib";
use VCL::utils;

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
unlink("/tmp/vcl-fw-test-vcld.conf");
exit($failures ? 1 : 0);
