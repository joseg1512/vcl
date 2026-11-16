#!/bin/sh
###############################################################################
# Runs the firewall unit tests of the Linux management node modules and exits
# with the worst (highest) exit code of the three, so a failure in any of them
# makes the runner fail.
#
# Usage (from anywhere, the path to the tests is resolved from this script):
#   managementnode/tests/run_firewall_tests.sh
#
# The tests do not need a management node, a database or root: they load the
# modules with a throwaway vcld.conf and stub the remote command execution.
###############################################################################

tests_directory=$(cd "$(dirname "$0")" && pwd)/firewall

worst_status=0
for test_name in test_vcld_conf.pl test_allowed_source.pl test_ubuntu_paths.pl test_chain_name_trim.pl; do
	printf '=== %s\n' "$test_name"
	perl "$tests_directory/$test_name"
	test_status=$?
	if [ "$test_status" -gt "$worst_status" ]; then
		worst_status=$test_status
	fi
done

printf '=== worst exit status: %s\n' "$worst_status"
exit "$worst_status"
