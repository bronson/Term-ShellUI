#!/usr/bin/env perl -w

use strict;
use Test::More tests => 2;

use Term::ShellUI;

# try to fix the "Cannot open /dev/tty for read" errors using
# the 2-argument version of the Term::ReadLine constructor.
my $term = Term::ShellUI->new(
	term => new Term::ReadLine("Test", *STDIN, *STDOUT)
	);
ok(defined $term,				'new returned something' );
ok($term->isa('Term::ShellUI'),	'and it\'s the right class' );

# TODO:
# add_commands
# get_deep_command
# call_cmd
# completion_function
