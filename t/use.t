#!/usr/bin/env perl -Tw

use strict;
use Test::More tests => 2;

use Term::GDBUI;

my $term = Term::GDBUI->new;
ok(defined $term,				'new returned something' );
ok($term->isa('Term::GDBUI'),	'and it\'s the right class' );

# add_commands
# get_deep_command
# call_cmd
# completion_function
