#!/usr/bin/env perl -Tw

use strict;
use FreezeThaw qw(cmpStr);

use lib 't';
use Parse;

use Test::Simple tests => 0+keys(%Parse::Tests);


use Text::Shellwords::Cursor;

my $parser = new Text::Shellwords::Cursor;
die "No parser" unless $parser;

for my $input (sort keys %Parse::Tests) {
	my($index,$cpos,$test) = $input =~ /^(\d+):(\d*):(.*)$/;
	die "No test in item $index:    $input\n" unless defined $test;

	my($toks, $tokno, $tokoff) = $parser->parse_line($test, messages=>0, cursorpos=>$cpos);
	my $result = [$toks, $tokno, $tokoff];
	ok(0 == cmpStr($result, $Parse::Tests{$input}), "Test $index");
}

