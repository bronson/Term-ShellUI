# Term::GDBUI.pm
# Scott Bronson
# 3 Nov 2003

# Makes it very easy to implement a GDB-like interface.

package Term::GDBUI;

use strict;

use Term::ReadLine ();

use vars qw($VERSION);
$VERSION = '0.61';

=head1 NAME

Term::GDBUI - A Bash/GDB-like command-line environment with autocompletion.

=head1 SYNOPSIS

 use Term::GDBUI;
 my $term = new Term::GDBUI(commands => get_commands());
 $term->run();

get_commands() returns a L<command set|/"COMMAND SET">, described
below in the L<COMMAND SET> section.

=head1 DESCRIPTION

This class uses the history and autocompletion features of Term::ReadLine
to present a sophisticated command-line interface.  It supports history,
autocompletion, quoting/escaping, pretty much everything you would expect
of a good shell.

To use this class, you just need to create a command set that
fully describes your user interface.  You need to write almost no code!


=head1 METHODS

=over 4

=item new Term::GDBUI

Creates a new GDBUI object.

It accepts the following named parameters:

=over 3

=item app

The name of this application as passed to L<Term::ReadLine::new>.
Defaults to $0, the name of the current executable.

=item blank_repeats_cmd

GDB re-executes the previous command when you enter a blank line.
Bash simply presents you with another prompt.  Pass 1 to get
Term::GDBUI to emulate GDB's behavior or 0 to enable Bash's,
the default (GDBUI's name notwithstanding).

=item commands

A hashref containing all the commands that GDBUI will respond to.
The format of this data structure can be found below in the
L<COMMAND SET> section.
If you do not supply any commands to the constructor, you must call
the L<commands> method to provide at least a minimal command set before
using many of the following calls.  You may add or delete commands or
even change the entire command set at any time.

=item history_file

This tells whether or not we should save the command history to
a file in the user's home directory.  By default history_file is
undef and we don't load or save the command history.

To enable history saving, supply a filename with this argument.
Tilde expansion is performed, so something like
"~/.myprog-history" is perfectly acceptable.

=item history_max

This tells how many items to save to the history file.
The default is 64.

Note that this parameter does not affect in-memory history.  This module
makes no attemt to cull history so you're at the mercy
of the default of whatever ReadLine library you are using.  History
may grow without bound (no big deal in this day of 1 gigabyte workstations).
See i.e. Term::ReadLine::Gnu::StifleHistory() for one way to change this.

=item keep_quotes

If you pass keep_quotes=>1, then quote marks found surrounding the
tokens will not be stripped.  Normally all unescaped, unnecessary
quote marks are removed.

=item prompt

This is the prompt that should be displayed for every request.
It can be changed at any time using the L<prompt> method.
The default is "$0> " (see "app" above).

=item token_chars

This argument specifies the characters that should be considered
tokens all by themselves.  For instance, if I pass
token_chars=>'=', then 'ab=123' would be parsed to ('ab', '=', '123'.)
token_chars is simply a string containing all token characters.

NOTE: you cannot change token_chars after the constructor has been
called!  The regexps that use it are compiled once (m//o).

=back

By default, the terminal has ornaments (text trickery to make the
command line stand out) turned off.  You can re-enable ornaments
by calling $gdbui->{term}->ornaments(arg) where arg is described in
L<Term::ReadLine::ornaments>.

=cut

sub new
{
	my $type = shift;
	my %args = (
		app => $0,
		prompt => "$0> ",
		commands => undef,
		blank_repeats_cmd => 0,
		history_file => undef,
		history_max => 64,
		token_chars => '',
		keep_quotes => 0,
		debug_complete => 0,
		@_
	);

	my $self = {};
	bless $self, $type;

	$self->{done} = 0;

	# expand tildes in the history file
	if($args{history_file}) {
		$args{history_file} =~ s/^~([^\/]*)/$1?(getpwnam($1))[7]:
			$ENV{HOME}||$ENV{LOGDIR}||(getpwuid($>))[7]/e;
	}

	for(qw(prompt commands blank_repeats_cmd history_file
		history_max token_chars keep_quotes debug_complete)) {
		$self->{$_} = $args{$_};
	}

	# used by join_line, tells how to space single-character tokens
	$self->{space_none} = '(';
	$self->{space_before} = '[{';
	$self->{space_after} = ',)]}';

	$self->{term} = new Term::ReadLine $args{'app'};
	$self->{term}->ornaments(0);	# turn off decoration by default
	$self->{term}->Attribs->{completion_function} =
		sub { completion_function($self, @_); };
	$self->{term}->MinLine(0);	# manually call AddHistory
	$self->{OUT} = $self->{term}->OUT || \*STDOUT;

	$self->{prevcmd} = "";	# cmd to run again if user hits return

	return $self;
}


# This is a utility function that implements a getter/setter.
# Pass the field to modify for $self, and the new value for that
# field (if any) in $new.

sub getset
{
	my $self = shift;
	my $field = shift;
	my $new = shift;  # optional

	my $old = $self->{$field};
	$self->{$field} = $new if defined $new;
	return $old;
}


=item prompt

If supplied with an argument, this method sets the command-line prompt.
Returns the old prompt.

=cut

sub prompt { return shift->getset('prompt', shift); }


=item commands

If supplied with an argument, it sets the current command set.
This can be used to change the command set at any time.
Returns the old command set.

=cut

sub commands { return shift->getset('commands', shift); }


=item add_commands

Adds all the commands in the supplied command set
to the current command set.
Replaces any commands in the current command set that have the same name.

=cut

sub add_commands
{
	my $self = shift;
	my $cmds = shift;

	my $cset = $self->commands() || {};
	for (keys %$cmds) {
		$cset->{$_} = $cmds->{$_};
	}
}

=item exit_requested

If supplied with an argument, sets the finished flag
to the argument (1=exit, 0=don't exit).  So, to get the
interpreter to exit at the end of processing the current
command, call $self->exit_requested(1).
Returns the old state of the flag.

=cut

sub exit_requested { return shift->getset('done', shift); }


=item blank_line

This routine is called when the user inputs a blank line.
It should return a string that is the command to run or
undef if nothing should happen.

By default, GDBUI simply presents another command line.  Pass
blank_repeats_cmd=>1 to L<new> to get GDBUI to repeat the previous
command.  Override this method to supply your own behavior.

=cut

sub blank_line
{
	my $self = shift;

	if($self->{blank_repeats_cmd}) {
		my $OUT = $self->{OUT};
		print $OUT $self->{prevcmd}, "\n";
		return $self->{prevcmd};
	}

	return undef;
}


=item error

Called when an error occurrs.  By default, the routine simply
prints the msg to stderr.  Override it to change this behavior.

     $self->error("Oh no!  That was terrible!\n");

=cut

sub error
{
	my $self = shift;
	print STDERR @_;
}


=item get_deep_command

Looks up the supplied command line in a command hash.
Follows all synonyms and subcommands.
Returns undef if the command could not be found.

	my($cset, $cmd, $cname, $args) =
		$self->get_deep_command($self->commands(), $tokens);

This call takes two arguments:

=over 3

=item cset

This is the command set to use.  Pass $self->commands()
unless you know exactly what you're doing.

=item tokens

This is the command line that the command should be read from.
It is a reference to an array that has already been split
on whitespace using L<parse_line>.

=back

and it returns a list of 4 values:

=over 3

=item 1

cset: the deepest command set found.  Always returned.

=item 2

cmd: the command hash for the command.  Undef if no command was found.

=item 3

cname: the full name of the command.  This is an array of tokens,
i.e. ('show', 'info').  Returns as deep as it could find commands
even if the final command was not found.

=item 4

args: the command's arguments (all remaining tokens after the
command is found).

=back

=cut

sub get_deep_command
{
	my $self = shift;
	my $cset = shift;
	my $tokens = shift;
	my $curtok = shift || 0;	# points to the command name

	#print "get_deep_cmd: $cset $#$tokens(" . join(",", @$tokens) . ") $curtok\n";

	my $name = $tokens->[$curtok];

	# loop through all synonyms to find the actual command
	while(exists($cset->{$name}) && exists($cset->{$name}->{'syn'})) {
		$name = $cset->{$name}->{'syn'};
	}

	my $cmd = $cset->{$name};

	# update the tokens with the actual name of this command
	$tokens->[$curtok] = $name;

	# should we recurse into subcommands?
	#print "$cmd  " . exists($cmd->{'subcmds'}) . "  (" . join(",", keys %$cmd) . ")   $curtok < $#$tokens\n";
	if($cmd && exists($cmd->{cmds}) && $curtok < $#$tokens) {
		#print "doing subcmd\n";
		my $subname = $tokens->[$curtok+1];
		my $subcmds = $cmd->{cmds};
		return $self->get_deep_command($subcmds, $tokens, $curtok+1);
	}

	#print "splitting (" . join(",",@$tokens) . ") at curtok=$curtok\n";

	# split deep command name and its arguments into separate lists
	my @cname = @$tokens;
	my @args = ($#cname > $curtok ? splice(@cname, $curtok+1) : ());

	#print "tokens (" . join(",",@$tokens) . ")\n";
	#print "cname (" . join(",",@cname) . ")\n";
	#print "args (" . join(",",@args) . ")\n";

	return ($cset, $cmd, \@cname, \@args);
}


=item get_cname

This is a tiny utility function that turns the cname (array ref
of names for this command as returned by L<get_deep_command>) into
a human-readable string.
This function exists only to ensure that we do this consistently.

=cut

sub get_cname
{
	my $self = shift;
	my $cname = shift;

	return join(" ", @$cname);
}


=item get_cset_completions

Returns a list of commands from the passed command set that are suitable
for completing.

It would be nice if we could return one set of completions
(without synonyms) to be displayed when the user hits tab twice,
and another set (with synonyms) to actually complete on.

=cut

sub get_cset_completions
{
	my $self = shift;
	my $cset = shift;

	# returns all non-synonym command names.  This used to be the
	# default, but it seemed more confusting than the alternative.
	# return grep {!exists($cset->{$_}->{syn}) } keys(%$cset);

	return grep {!exists $cset->{$_}->{exclude_from_completion}} keys(%$cset);

	#return keys(%$cset);
}


=item completemsg

your completion routine should call this to display text onscreen
without messing up the command line being completed.  If your
completion routine prints text without calling completemsg,
the cursor will no longer be displayed in the correct position.

    $self->completemsg("You cannot complete here!\n");

=cut

sub completemsg
{
	my $self = shift;
	my $msg = shift;

	my $OUT = $self->{OUT};
	print $OUT $msg;
	$self->{term}->rl_on_new_line();
}


=item complete

complete performs the default top-level command-line completion.
Note that is not called directly by ReadLine.  Rather, ReadLine calls
L<completion_function> which tokenizes the input and performs some
housekeeping, then completion_function calls this one.

You should override this routine if your application has custom
completion needs (like non-trivial tokenizing).  If you override
this routine, you will probably need to override L<call_cmd> as well.

The one parameter, cmpl, is a data structure that contains all the
information you need to calculate the completions.
Set $self->{debug_complete}=5 to see the contents of cmpl.
Here are the items in cmpl:

=over 3

=item str

The exact string that needs completion.  Often you don't need anything
more than this.

=item cset

Command set for the deepest command found (see L<get_deep_command>).
If no command was found then cset is set to the topmost command
set ($self->commands()).

=item cmd

The command hash for deepest command found or
undef if no command was found (see L<get_deep_command>).
cset is the command set that contains cmd.

=item cname

The full name of deepest command found as an array of tokens (see L<get_deep_command>).

=item args

The arguments (as a list of tokens) that should be passed to the command
(see L<get_deep_command>).  Valid only if cmd is non-null.  Undef if no
args were passed.

=item argno

The index of the argument (in args) containing the cursor.

=item tokens

The tokenized command-line.

=item tokno

The index of the token containing the cursor.

=item tokoff

The character offset of the cursor in the token.

For instance, if the cursor is on the first character of the 
third token, tokno will be 2 and tokoff will be 0.

=item twice

True if user has hit tab twice in a row.  This usually means that you
should print a message explaining the possible completions.

If you return your completions as a list, then $twice is handled
for you automatically.  You could use it, for instance, to display
an error message (using L<completemsg>) telling why no completions
could be found.

=item rawline

The command line as a string, exactly as entered by the user.

=item rawstart

The character position of the cursor in rawline.

=back

=cut

sub complete
{
	my $self = shift;
	my $cmpl = shift;

	my $cset = $cmpl->{cset};
	my $cmd = $cmpl->{cmd};

	if($cmpl->{tokno} < @{$cmpl->{cname}}) {
		# if we're still in the command, return possible command completions
		return $self->get_cset_completions($cset);
	}

	my @retval = ();
	if(!$cmd) {
		# don't do nuthin'
	} elsif(exists($cmd->{args})) {
		if(ref($cmd->{args}) eq 'CODE') {
			@retval = &{$cmd->{args}}($self, $cmpl);
		} elsif(ref($cmd->{args}) eq 'ARRAY') {
			# each element in array is a string describing corresponding argument
			my $arg = $cmd->{args}->[$cmpl->{argno}];
			if(!defined $arg) {
				# do nothing
			} elsif(ref($arg) eq 'CODE') {
				# it's a routine to call for this particular arg
				@retval = &$arg($self, $cmpl);
			} elsif(ref($arg) eq 'ARRAY') {
				# it's an array of possible completions
				@retval = @$arg;
			} else {
				# it's a string reiminder of what this arg is meant to be
				$self->completemsg("$arg\n") if $cmpl->{twice};
			}
		} elsif(ref($cmd->{args}) eq 'HASH') {
			# not supported yet!  (if ever...)
		} else {
			# this must be a string describing all arguments.
			$self->completemsg($cmd->{args} . "\n") if $cmpl->{twice};
		}
	}

	return @retval;
}


=item completion_function

This is the entrypoint to the ReadLine completion callback.
It sets up a bunch of data, then calls L<complete> to calculate
the actual completion.

To watch and debug the completion process, you can set $self->{debug_complete}
to 2 (print tokenizing), 3 (print tokenizing and results) or 4 (print
everything including the cmpl data structure).

Youu should never need to call or override this function.  If
you do (but, trust me, you don't), set
$self->{term}->Attribs->{completion_function} to point to your own
routine.

See the L<Term::ReadLine> documentation for a description of the arguments.

=cut

sub completion_function
{
	my $self = shift;
	my $text = shift;	# the word directly to the left of the cursor
	my $line = shift;	# the entire line
	my $start = shift;	# the position in the line of the beginning of $text

	my $cursor = $start + length($text);

	# Twice is true if the user has hit tab twice on the same string
	my $twice = ($self->{completeline} eq $line);
	$self->{completeline} = $line;

	my($tokens, $tokno, $tokoff) = $self->parse_line($line,
		messages=>0, cursorpos=>$cursor, fixclosequote=>1);
	return unless defined($tokens);

	# this just prints a whole bunch of completion/parsing debugging info
	if($self->{debug_complete} > 1) {
		print "\ntext='$text', line='$line', start=$start, cursor=$cursor";

		print "\ntokens=(", join(", ", @$tokens), ") tokno=" . 
			(defined($tokno) ? $tokno : 'undef') . " tokoff=" .
			(defined($tokoff) ? $tokoff : 'undef');

		print "\n";
		my $str = " ";
		print     "<";
		my $i = 0;
		for(@$tokens) {
			my $s = (" " x length($_)) . " ";
			substr($s,$tokoff,1) = '^' if $i eq $tokno;
			$str .= $s;
			print $_;
			print ">";
			$str .= "   ", print ", <" if $i != $#$tokens;
			$i += 1;
		}
		print "\n$str\n";
		$self->{term}->rl_on_new_line();
	}

	my $str = substr($tokens->[$tokno], 0, $tokoff);

	my($cset, $cmd, $cname, $args) = $self->get_deep_command($self->commands(), $tokens);

	# this structure hopefully contains everything you'll ever
	# need to easily compute a match.
	my $cmpl = {
		str => $str,			# the exact string that needs completion
								# (usually, you don't need anything more than this)

		cset => $cset,			# cset of the deepest command found
		cmd => $cmd,			# the deepest command or undef
		cname => $cname,		# full name of deepest command
		args => $args,			# anything that was determined to be an argument.
		argno => $tokno - @$cname,	# the argument containing the cursor

		tokens => $tokens,		# tokenized command-line (arrayref).
		tokno => $tokno,		# the index of the token containing the cursor
		tokoff => $tokoff,		# the character offset of the cursor in $tokno.
		twice => $twice,		# true if user has hit tab twice in a row

		rawline => $line,		# pre-tokenized command line
		rawstart => $start,		# position in rawline of the cursor
	};

	if($self->{debug_complete} > 3) {
		print "tokens=(" . join(",", @$tokens) . ") tokno=$tokno tokoff=$tokoff str=$str twice=$twice\n";
		print "cset=$cset cmd=" . (defined($cmd) ? $cmd : "(undef)") .
			" cname=(" . join(",", @$cname) . ") args=(" . join(",", @$args) . ") argno=$tokno\n";
	}

	my @retval = $self->complete($cmpl);

	if($self->{debug_complete} > 2) {
		print "returning (", join(", ", @retval), ")\n";
	}

	# escape the completions so they're valid on the command line
	$self->parse_escape(\@retval);

	return @retval;
}


# Converts a field name into a text string.
# All fields can be code, if so, then they're called to return string value.
# You need to ensure that the field exists before calling this routine.

sub get_field
{
	my $self = shift;
	my $cmd = shift;
	my $field = shift;
	my $args = shift;

	my $val = $cmd->{$field};

	if(ref($val) eq 'CODE') {
		return &$val($self, $cmd, @$args);
	}

	return $val;
}


=item get_cmd_summary

Prints a one-line summary for the given command.

=cut

sub get_cmd_summary
{
	my $self = shift;
	my $tokens = shift;
	my $topcset = shift || $self->commands();

	# print "print_cmd_summary: cmd=$cmd args=(" . join(", ", @$args), ")\n";

	my($cset, $cmd, $cname, $args) = $self->get_deep_command($topcset, $tokens);
	if(!$cmd) {
		return $self->get_cname($cname) . " doesn't exist.\n";
	}

	my $desc = $self->get_field($cmd, 'desc', $args) || "(no description)";
	return sprintf("%20s -- $desc\n", $self->get_cname($cname));
}


=item get_cmd_help

Prints the full help text for the given command.

=cut

sub get_cmd_help
{
	my $self = shift;
	my $tokens = shift;
	my $topcset = shift || $self->commands();

	my $str = "";

	# print "print_cmd_help: cmd=$cmd args=(" . join(", ", @$args), ")\n";

	my($cset, $cmd, $cname, $args) = $self->get_deep_command($topcset, $tokens);
	if(!$cmd) {
		return $self->get_cname($cname) . " doesn't exist.\n";
	}

	if(exists($cmd->{desc})) {
		$str .= $self->get_cname($cname).": ".$self->get_field($cmd,'desc',$args)."\n";
	} else {
		$str .= "No description for " . $self->get_cname($cname) . "\n";
	}

	if(exists($cmd->{doc})) {
		$str .= $self->get_field($cmd, 'doc', $args);
	} elsif(exists($cmd->{cmds})) {
		$str .= $self->get_all_cmd_summaries($cmd->{cmds});
	} else {
		# no data -- do nothing
	}

	return $str;
}


=item get_category_summary

Prints a one-line summary for the catgetory named $name
in the category hash $cat.

=cut

sub get_category_summary
{
	my $self = shift;
	my $name = shift;
	my $cat = shift;

	my $title = $cat->{desc} || "(no description)";
	return sprintf("%20s -- $title\n", $name);
}

=item get_category_help

Returns a string containing the full help for the catgetory named
$name and passed in $cat.  The full help is a list of one-line
summaries of the commands in this category.

=cut

sub get_category_help
{
	my $self = shift;
	my $cat = shift;
	my $cset = shift;

	my $str .= "\n" . $cat->{desc} . "\n\n";
	for my $name (@{$cat->{cmds}}) {
		my @line = split /\s+/, $name;
		$str .= $self->get_cmd_summary(\@line, $cset);
	}
	$str .= "\n";

	return $str;
}


=item get_all_cmd_summaries

Pass it a command set, and it will return a string containing
the summaries for each command in the set.

=cut

sub get_all_cmd_summaries
{
	my $self = shift;
	my $cset = shift;

	my $str = "";

	for(keys(%$cset)) {
		next unless exists $cset->{$_}->{desc};
		$str .= $self->get_cmd_summary([$_], $cset);
	}

	return $str;
}



=item load_history

If $self->{history_file} is set (see L<new>), this will load all
history from that file.  Called by L<run> on startup.  If you
don't use run, you will need to call this command manually.

=cut

sub load_history
{
	my $self = shift;

	return unless $self->{history_file} && $self->{history_max} > 0;

	if(open HIST, '<'.$self->{history_file}) {
		while(<HIST>) {
			chomp();
			next unless /\S/;
			$self->{term}->addhistory($_);
		}
		close HIST;
	}
}

=item save_history

If $self->{history_file} is set (see L<new>), this will save all
history to that file.  Called by L<run> on shutdown.  If you
don't use run, you will need to call this command manually.

The history routines don't use ReadHistory and WriteHistory so they
can be used even if other ReadLine libs are being used.  save_history
requires that the ReadLine lib supply a GetHistory call.

=cut

sub save_history
{
	my $self = shift;

	return unless $self->{history_file} && $self->{history_max} > 0;
	return unless $self->{term}->can('GetHistory');

	my @list = $self->{term}->GetHistory();
	return unless(@list);

	my $max = $#list;
	$max = $self->{history_max}-1 if $self->{history_max}-1 < $max;

	if(open HIST, '>'.$self->{history_file}) {
		local $, = "\n";
		print HIST @list[0..$max];
		close HIST;
	} else {
		$self->error("Could not open ".$self->{history_file}." for writing $!\n");
	}
}


=item call_cmd

Executes a command and returns the result.  It takes a single
argument: the parms data structure.

parms is a subset of the cmpl data structure (see the L<complete>
routine for more).  Briefly, it contains: 
cset, cmd, cname, args (see L<get_deep_command>),
tokens and rawline (the tokenized and untokenized command lines).
See L<complete> for full descriptions of these fields.

This call should be overridden if you have exotic command
processing needs.  If you override this routine, you will probably
need to override the L<complete> routine too.

=cut

sub call_cmd
{
	my $self = shift;
	my $parms = shift;

	my $OUT = $self->{OUT};
	my $retval = undef;

	if(!$parms->{cmd}) {
		$self->error( $self->get_cname($parms->{cname}) . " doesn't exist.\n");
		goto bail;
	}

	my $cmd = $parms->{cmd};

	# check min and max args if they exist
	if(exists($cmd->{minargs}) && @{$parms->{args}} < $cmd->{minargs}) {
		$self->error("Too few args!  " . $cmd->{minargs} . " minimum.\n");
		goto bail;
	}
	if(exists($cmd->{maxargs}) && @{$parms->{args}} > $cmd->{maxargs}) {
		$self->error("Too many args!  " . $cmd->{maxargs} . " maximum.\n");
		goto bail;
	}

	if(exists $cmd->{meth}) {
		# if meth is a code ref, call it, else it's a string, print it.
		if(ref($cmd->{meth}) eq 'CODE') {
			$retval = eval { &{$cmd->{meth}}($self, $parms, @{$parms->{args}}) };
			$self->error($@) if $@;
		} else {
			print $OUT $cmd->{meth};
		}
	} elsif(exists $cmd->{proc}) {
		# if proc is a code ref, call it, else it's a string, print it.
		if(ref($cmd->{proc}) eq 'CODE') {
			$retval = eval { &{$cmd->{proc}}(@{$parms->{args}}) };
			$self->error($@) if $@;
		} else {
			print $OUT $cmd->{proc};
		}
	} else {
		if(exists $cmd->{cmds}) {
			# if not, but it has subcommands, then print a summary
			print $OUT $self->get_all_cmd_summaries($cmd->{cmds});
		} else {
			$self->error($self->get_cname($parms->{cname}) . " has nothing to do!\n");
		}
	}

	return $retval;
}


=item process_a_cmd

Prompts for and returns the results from a single command.
Returns undef if no command was called.

=cut

sub process_a_cmd
{
	my $self = shift;

	$self->{completeline} = "";

	my $rawline = $self->{term}->readline($self->prompt());

	my $OUT = $self->{'OUT'};

	# EOF exits
	unless(defined $rawline) {
		print $OUT "\n";
		$self->exit_requested(1);
		return undef;
	}

	# is it a blank line?
	if($rawline =~ /^\s*$/) {
		$rawline = $self->blank_line();
		return unless defined $rawline && $rawline !~ /^\s*$/;
	}

	my $retval = undef;
	my $str = $rawline;

	my ($tokens) = $self->parse_line($rawline, messages=>1);
	if(defined $tokens) {
		$str = $self->join_line($tokens);
		my($cset, $cmd, $cname, $args) = $self->get_deep_command($self->commands(), $tokens);

		# this is a subset of the cmpl data structure
		my $parms = {
			cset => $cset,
			cmd => $cmd,
			cname => $cname,
			args => $args,
			tokens => $tokens,
			rawline => $rawline,
		};

		$retval = $self->call_cmd($parms);
	}

bail:
	# Add to history unless it's a dupe of the previous command.
	$self->{term}->addhistory($str) if $str ne $self->{prevcmd};
	$self->{prevcmd} = $str;

	return $retval;
}


=item run

The main loop.  Processes all commands until someone calls
L<exit_requested>(true).

=cut

sub run
{
	my $self = shift;

	$self->load_history();

	while(!$self->{done}) {
		$self->process_a_cmd();
	}

	$self->save_history();
}


=back



=head1 CALLBACKS

These functions are meant to be called by the commands themselves
(usually via the 'meth' field).
They offer some assistance in implementing common functions like 'help'.

=over 4



=item help_call

Help commands can call this routine to print information about
command sets.

=over 3

=item cats

A hash of available help categories (see L<CATEGORIES> below
for more).  Pass undef if you don't have any help categories.

=item topic

The item upon which help should be printed (the arguments to the
help command.

=back

Here is the most common way to implement a help command:

  "help" =>   { desc => "Print helpful information",
                args => sub { shift->help_args($helpcats, @_); },
                meth => sub { shift->help_call($helpcats, @_); } },

This follows synonyms and subcommands, completing the entire
way.  It works exactly as you'd expect.

=cut

sub help_call
{
	my $self = shift;
	my $cats = shift;		# help categories to use
	my $parms = shift;		# data block passed to methods
	my $topic = $_[0];		# topics or commands to get help on

	my $cset = $parms->{cset};
	my $OUT = $self->{OUT};

	if(defined($topic)) {
		if(exists $cats->{$topic}) {
			print $OUT $self->get_category_help($cats->{$topic}, $cset);
		} else {
			print $OUT $self->get_cmd_help(\@_, $cset);
		}
	} elsif(defined($cats)) {
		# no topic -- print a list of the categories
		print $OUT "\nHelp categories:\n\n";
		for(keys(%$cats)) {
			print $OUT $self->get_category_summary($_, $cats->{$_});
		}
	} else {
		# no categories -- print a summary of all commands
		print $OUT $self->get_all_cmd_summaries($cset);
	}
}

=item help_args

This provides argument completion for help commands.
Call this as shown in the example in L<help_call>.

=cut

sub help_args
{
	my $self = shift;
	my $helpcats = shift;
	my $cmpl = shift;

	my $args = $cmpl->{'args'};
	my $argno = $cmpl->{'argno'};
	my $cset = $cmpl->{'cset'};

	if($argno == 1) {
		# return both categories and commands if we're on the first argument
		return ($self->get_cset_completions($cset), keys(%$helpcats));
	}

	my($scset, $scmd, $scname, $sargs) = $self->get_deep_command($cset, $args);

	# without this we'd complete with $scset for all further args
	return () if $argno > @$scname;

	return $self->get_cset_completions($scset);
}



=item complete_files

Allows any command to easily complete on objects from the filesystem.
Call it using either "args => sub { shift->complete_files(@_)" or
"args => \&complete_files".  See the "ls" example in the L<COMMAND SET>
section below.

=cut

sub complete_files
{
	my $self = shift;
	my $cmpl = shift;
	my $dir = shift || '.';

	# don't complete if user has gone past max # of args
	return () if exists($cmpl->{cmd}->{maxargs}) && $cmpl->{argno} > $cmpl->{cmd}->{maxargs};

	my $str = $cmpl->{str};
	my $len = length($str);

	my @files = ();
	if(opendir(DIR, $dir)) {
		@files = grep { substr($_,0,$len) eq $str } readdir DIR;
		closedir DIR;
	}

	return @files;
}


=item complete_onlyfiles

Like L<complete_files>, but excludes directories, device nodes, etc.
It returns regular files only.

=cut

sub complete_onlyfiles
{
	return grep { -f } shift->complete_files(@_);
}


=item complete_onlydirs

Like L<complete_files>, but excludes files, device nodes, etc.
It returns only directories.  
It I<does> return the . and .. special directories so you'll need
to remove those manually if you don't want to see them.

=cut

sub complete_onlydirs
{
	return grep { -d } shift->complete_files(@_);
}


=back

=head1 TOKEN PARSING

Term::GDBUI used to use the Text::ParseWords module to
tokenize the command line.  However, requirements have gotten
significantly more complex since then, forcing this module
to do all tokenizing itself. 

=over 3

=item parsebail

If the parsel routine or any of its subroutines runs into a fatal
error, they call parsebail to present a very descriptive diagnostic.

=cut

sub parsebail
{
	my $self = shift;
	my $msg = shift;
	my $line = "";

	die "$msg at char " . pos() . ":\n",
	"    $_\n    " . (' ' x pos()) . '^' . "\n";

}


=item parsel

This is the heinous routine that actually does the parsing.
You should never need to call it directly.  Call L<parse_line>
instead.

=cut

sub parsel
{
	my $self = shift;
	$_ = shift;
	my $cursorpos = shift;
	my $fixclosequote = shift;

	my $deb = $self->{debug};
	my $tchrs = $self->{token_chars};

	my $usingcp = (defined($cursorpos) && $cursorpos ne '');
	my $tokno = undef;
	my $tokoff = undef;
	my $oldpos;

	my @pieces = ();

	# Need to special case the empty string.  None of the patterns below
	# will match it yet we need to return an empty token for the cursor.
	return ([''], 0, 0) if $usingcp && $_ eq '';

	/^/gc;  # force scanning to the beginning of the line

	do {
		$deb && print "-- top, pos=" . pos() . " cursorpos=$cursorpos\n";

		# trim whitespace from the beginning
		if(/\G(\s+)/gc) {
			$deb && print "trimmed " . length($1) . " whitespace chars, cursorpos=$cursorpos\n";
			# if pos passed cursorpos, then we know that the cursor was
			# surrounded by ws and we need to create an empty token for it.
			if($usingcp && (pos() >= $cursorpos)) {
				# if pos == cursorpos and we're not yet at EOL, let next token accept cursor
				unless(pos() == $cursorpos && pos() < length($_)) {
					# need to special-case at end-of-line as there are no more tokens
					# to take care of the cursor so we must create an empty one.
					$deb && print "adding bogus token to handle cursor.\n";
					push @pieces, '';
					$tokno = $#pieces;
					$tokoff = 0;
					$usingcp = 0;
				}
			}
		}

		# if there's a quote, then suck to the close quote
		$oldpos = pos();
		if(/\G(['"])/gc) {
			my $quote = $1;
			my $adjust = 0;	# keeps track of tokoff bumps due to subs, etc.
			my $s;

			$deb && print "Found open quote [$quote]  oldpos=$oldpos\n";

			# adjust tokoff unless the cursor sits directly on the open quote
			if($usingcp && pos()-1 < $cursorpos) {
				$deb && print "  lead quote increment   pos=".pos()." cursorpos=$cursorpos\n";
				$adjust += 1;
			}

			if($quote eq '"') {
				if(/\G((?:\\.|(?!["])[^\\])*)["]/gc) {
					$s = $1;	# string without quotes
				} else {
					unless($fixclosequote) {
						pos() -= 1;
						$self->parsebail("need closing quote [\"]");
					}
					/\G(.*)$/gc;	# if no close quote, just suck to the end of the string
					$s = $1;	# string without quotes
					if($usingcp && pos() == $cursorpos) { $adjust -= 1; }	# make cursor think cq was there
				}
				$deb && print "  quoted string is \"$s\"\n";
				while($s =~ /\\./g) { 
					my $ps = pos($s) - 2; 	# points to the start of the sub
					$deb && print "  doing substr at $ps on '$s'  oldpos=$oldpos adjust=$adjust\n";
					$adjust += 1 if $usingcp && $ps < $cursorpos - $oldpos - $adjust;
					substr($s, $ps, 1) = '';
					pos($s) = $ps + 1;
					$deb && print "  s='$s'  usingcp=$usingcp  pos(s)=" . pos($s) . "  cursorpos=$cursorpos  oldpos=$oldpos adjust=$adjust\n";
				}
			} else {
				if(/\G((?:\\.|(?!['])[^\\])*)[']/gc) {
					$s = $1;	# string without quotes
				} else {
					unless($fixclosequote) {
						pos() -= 1;
						$self->parsebail("need closing quote [']");
					}
					/\G(.*)$/gc;	# if no close quote, just suck to the end of the string
					$s = $1;
					if($usingcp && pos() == $cursorpos) { $adjust -= 1; }	# make cursor think cq was there
				}
				$deb && print "  quoted string is '$s'\n";
				while($s =~ /\\[\\']/g) { 
					my $ps = pos($s) - 2; 	# points to the start of the sub
					$deb && print "  doing substr at $ps on '$s'  oldpos=$oldpos adjust=$adjust\n";
					$adjust += 1 if $usingcp && $ps < $cursorpos - $oldpos - $adjust;
					substr($s, $ps, 1) = '';
					pos($s) = $ps + 1;
					$deb && print "  s='$s'  usingcp=$usingcp  pos(s)=" . pos($s) . "  cursorpos=$cursorpos  oldpos=$oldpos adjust=$adjust\n";
				}
			}

			# adjust tokoff if the cursor if it sits directly on the close quote
			if($usingcp && pos() == $cursorpos) {
				$deb && print "  trail quote increment  pos=".pos()." cursorpos=$cursorpos\n";
				$adjust += 1;
			}

			$deb && print "  Found close, pushing '$s'  oldpos=$oldpos\n";
			push @pieces, $self->{keep_quotes} ? $quote.$s.$quote : $s;

			# Set tokno and tokoff if this token contained the cursor
			if($usingcp && pos() >= $cursorpos) {
				# Previous block contains the cursor
				$tokno = $#pieces;
				$tokoff = $cursorpos - $oldpos - $adjust;
				$usingcp = 0;
			}
		}

		# suck up as much unquoted text as we can
		$oldpos = pos();
		if(/\G((?:\\.|[^\s\\"'\Q$tchrs\E])+)/gco) {
			my $s = $1;		# the unquoted string
			my $adjust = 0;	# keeps track of tokoff bumps due to subs, etc.

			$deb && print "Found unquoted string '$s'\n";
			while($s =~ /\\./g) { 
				my $ps = pos($s) - 2;	# points to the start of substitution
				$deb && print "  doing substr at $ps on '$s'  oldpos=$oldpos adjust=$adjust\n";
				$adjust += 1 if $usingcp && $ps < $cursorpos - $oldpos - $adjust;
				substr($s, $ps, 1) = '';
				pos($s) = $ps + 1;
				$deb && print "  s='$s'  usingcp=$usingcp  pos(s)=" . pos($s) . "  cursorpos=$cursorpos  oldpos=$oldpos adjust=$adjust\n";
			}
			$deb && print "  pushing '$s'\n";
			push @pieces, $s;

			# Set tokno and tokoff if this token contained the cursor
			if($usingcp && pos() >= $cursorpos) {
				# Previous block contains the cursor
				$tokno = $#pieces;
				$tokoff = $cursorpos - $oldpos - $adjust;
				$usingcp = 0;
			}
		}

		if(length($tchrs) && /\G([\Q$tchrs\E])/gco) {
			my $s = $1;	# the token char
			$deb && print "  pushing '$s'\n";
			push @pieces, $s;

			if($usingcp && pos() == $cursorpos) {
				# Previous block contains the cursor
				$tokno = $#pieces;
				$tokoff = 0;
				$usingcp = 0;
			}
		}
	} until(pos() >= length($_));

	$deb && print "Result: (", join(", ", @pieces), ") " . 
		(defined($tokno) ? $tokno : 'undef') . " " .
		(defined($tokoff) ? $tokoff : 'undef') . "\n";

	return ([@pieces], $tokno, $tokoff);
}


=item parse_line($line, $cursorpos)

This is the entrypoint to this module's parsing functionality.  It converts
a line into tokens, respecting quoted text, escaped characters,
etc.  It also keeps track of a cursor position on the input text,
returning the token number and offset within the token where that position
can be found in the output.

This routine originally bore some resemblance to Text::ParseWords.
It has changed almost completely, however, to support keeping track
of the cursor position.  It also has nicer failure modes, modular
quoting, token characters (see token_chars in L<new>), etc.  This
routine now does much more.

Arguments:

=over 3

=item line

This is a string containing the command-line to parse.

=back

This routine also accepts the following named parameters:

=over 3

=item cursorpos

This is the character position in the line to keep track of.
Pass undef (by not specifying it) or the empty string to have
the line processed with cursorpos ignored.

Note that passing undef is I<not> the same as passing
some random number and ignoring the result!  For instance, if you
pass 0 and the line begins with whitespace, you'll get a 0-length token at
the beginning of the line to represent the cursor in
the middle of the whitespace.  This allows command completion
to work even when the cursor is not near any tokens.
If you pass undef, all whitespace at the beginning and end of
the line will be trimmed as you would expect.

If it is ambiguous whether the cursor should belong to the previous
token or to the following one (i.e. if it's between two quoted
strings, say "a""b" or a token_char), it always gravitates to
the previous token.  This makes more sense when completing.

=item fixclosequote

Sometimes you want to try to recover from a missing close quote
(for instance, when calculating completions), but usually you
want a missing close quote to be a fatal error.  fixclosequote=>1
will implicitly insert the correct quote if it's missing.
fixclosequote=>0 is the default.

=item messages

parse_line is capable of printing very informative error messages.
However, sometimes you don't care enough to print a message (like
when calculating completions).  Messages are printed by default,
so pass messages=>0 to turn them off.

=back

This function returns a reference to an array containing three
items:

=over 3

=item tokens

A the tokens that the line was separated into (ref to an array of strings).

=item tokno

The number of the token (index into the previous array) that contains
cursorpos.

=item tokoff

The character offet into tokno of cursorpos.

=back

If the cursor is at the end of the token, tokoff will point to 1
character past the last character in tokno, a non-existant character.
If the cursor is between tokens (surrounded by whitespace), a zero-length
token will be created for it.

=cut

sub parse_line
{
	my $self = shift;
	my $line = shift;
	my %args = (
		messages => 1,		# true if we should print errors, etc.
		cursorpos => undef,	# cursor to keep track of, undef to ignore.
		fixclosequote => 0,
		@_
	);

	my @result = eval { $self->parsel($line,
		$args{'cursorpos'}, $args{'fixclosequote'}) };
	if($@) {
		$self->error($@) if $args{'messages'};
		@result = (undef, undef, undef);
	}

	return @result;
}


=item parse_escape

Escapes characters that would be otherwise interpreted by the parser.
Will accept either a single string or an arrayref of strings (which
will be modified in-place).

=cut

sub parse_escape
{
	my $self = shift;
	my $arr = shift;	# either a string or an arrayref of strings

	my $wantstr = 0;
	if(ref($arr) ne 'ARRAY') {
		$arr = [$arr];
		$wantstr = 1;
	}

	foreach(@$arr) {
		my $quote;
		if($self->{keep_quotes} && /^(['"])(.*)\1$/) {
			($quote, $_) = ($1, $2);
		}
		s/([ \\"'])/\\$1/g;
		$_ = $quote.$_.$quote if $quote;
	}

	return $wantstr ? $arr->[0] : $arr;
}


=item join_line

This routine does a somewhat intelligent job of joining tokens
back into a command line.  If token_chars (see L<new>) is empty
(the default), then it just escapes backslashes and quotes, and
joins the tokens with spaces.

However, if token_chars is nonempty, it tries to insert a visually
pleasing amount of space between the tokens.  For instance, rather
than 'a ( b , c )', it tries to produce 'a (b, c)'.  It won't reformat
any tokens that aren't found in $self->{token_chars}, of course.

To change the formatting, you can redefine the variables
$self->{space_none}, $self->{space_before}, and $self->{space_after}.
Each variable is a string containing all characters that should
not be surrounded by whitespace, should have whitespace before,
and should have whitespace after, respectively.  Any character
found in token_chars, but non in any of these space_ variables,
will have space placed both before and after.

=cut

sub join_line
{
	my $self = shift;
	my $intoks = shift;

	my $tchrs = $self->{token_chars};
	my $s_none = $self->{space_none};
	my $s_before = $self->{space_before};
	my $s_after = $self->{space_after};

	# copy the input array so we don't modify it
	my $tokens = $self->parse_escape([@$intoks]);

	my $str = '';
	my $sw = '';	# a space if space wanted after token.
	for(@$tokens) {
		if(length == 1 && index($tchrs,$_) >= 0) {
			if(index($s_none,$_) >= 0)   { $str .= $_;     $sw='';  next; }
			if(index($s_before,$_) >= 0) { $str .= $sw.$_; $sw='';  next; }
			if(index($s_after,$_) >= 0)  { $str .= $_;     $sw=' '; next; }
		}
		$str .= $sw.$_; $sw = ' ';
	}

	return $str;
}


=back


=head1 COMMAND SET

A command set describes your application's entire user interface.
 It's probably easiest to explain this with a working example.
Combine the following get_commands() routine with the
code shown in the L<SYNOPSIS> above, and you'll have a real-life
shellish thingy that supports the following commands:

=over 4

=item h

This is just a synonym for "help".  It is not listed in the possible
completions because it just clutters up the list without being useful.

=item help

The default implementation for the help command

=item ls

This command shows how to perform completion using the L<complete_files>
routine, how a proc can process its arguments, and how to provide
more comprehensive help.

=item show

This is an example showing how the GDB show command can be
implemented.  Both "show warranty" and "show args" are valid
subcommands.

=item show args

This is a hypothetical command.  It uses a static completion for the
first argument (either "create" or "delete") and the standard
file completion for the second.  When executed, it echoes its own command
name followed by its arguments.

=item quit

How to nicely quit.  Even if no quit command is supplied, Term::GDBUI
follows Term::ReadLine's default of quitting when Control-D is pressed.

=back

This code is rather large because it is intended to be reasonably
comprehensive and demonstrate most of the features supported by
Term::GDBUI's command set.  For a more reasonable example, see the
"fileman-example" file that ships with this module.

 sub get_commands
 {
     return {
         "h" =>      { syn => "help", exclude_from_completion=>1},
         "help" => {
             desc => "Print helpful information",
             args => sub { shift->help_args(undef, @_); },
             meth => sub { shift->help_call(undef, @_); }
         },
         "ls" => {
             desc => "List whether files exist",
             args => sub { shift->complete_files(@_); },
             proc => sub {
                 print "exists: " .
                     join(", ", map {-e($_) ? "<$_>":$_} @_) .
                     "\n";
             },
             doc => <<EOL,
 Comprehensive documentation for our ls command.
 If a file exists, it is printed in <angle brackets>.
 The help can\nspan\nmany\nlines
 EOL
         },
         "show" => {
             desc => "An example of using subcommands",
             cmds => {
                 "warranty" => { proc => "You have no warranty!\n" },
                 "args" => {
					 minargs => 2, maxargs => 2,
                     args => [ sub {qw(create delete)},
                               \&Term::GDBUI::complete_files ],
                     desc => "Demonstrate method calling",
                     meth => sub {
                         my $self = shift;
                         my $parms = shift;
                         print $self->get_cname($parms->{cname}) .
                             ": " . join(" ",@_), "\n";
                     },
                 },
             },
         },
         "quit" => {
             desc => "Quit using Fileman",
             maxargs => 0,
             meth => sub { shift->exit_requested(1); }
		 },
     };
 }


=head1 COMMAND HASH

A command is described by a relatively small number of fields: desc,
args, proc, meth, etc.  These fields are collected into a data
structure called a command hash.  A command set is simply a
collection of command hashes.

The following fields may be found in a command hash:

=over 4

=item desc

A short, one-line description for the command.  Normally this is
a simple string.

If you store a reference to a subroutine in this field, the routine
will be called to calculate the description to print.  Your
subroutine should accept two arguments, $self (the Term::GDBUI object),
and $cmd (the command hash for the command), and return a string
containing the command's description.

=item doc

A comprehensive, many-line description for the command.  Normally
this is stored as a simple string.

If you store a reference to a subroutine in this field, the routine
will be called to calculate the documentation.  Your
subroutine should accept two arguments: self (the Term::GDBUI object),
and cmd (the command hash for the command), and return a string
containing the command's documentation.

=item maxargs

=item minargs

These set the maximum and minimum number of arguments that this
command will accept.  By default, the command can accept any
number of arguments.

=item proc

This contains a reference to the subroutine that should be called
when this command should be executed.  Arguments are
those passed on the command line, return value is returned by
call_cmd and process_a_cmd (i.e. it is usually ignored).

If this field is a string instead of a subroutine ref, the string
(i.e. "Not implemented yet") is printed when the command is executed. 
Examples of both subroutine and string procs can be seen in the example
above.

proc is similar to meth, but only passes the command's arguments.

=item meth

Like proc, but includes more arguments.  Where proc simply passes
the arguments for the command, meth also passes the Term::GDBUI object
and the command's parms object (see L<call_cmd> for more on parms).

Like proc, meth may also be a string.  If a command has both a meth
and a proc, the meth takes precedence.

=item args

This tells how to complete the command's arguments.  It is usually
a subroutine.  See L<complete_files>) for an reasonably simple
example, and the L<complete> routine for a description of the
arguments and cmpl data structure.

Args can also be an arrayref.  Each position in the array will be
used as the corresponding argument.  For instance, if a command
takes two arguments, an operation and a file

Finally, args can also be a string that is a reminder and is printed
whenever the user types tab twice.

=item cmds

Command sets can be recursive.  This allows a command to implement
subcommands (like GDB's info and show).  The cmds field specifies
the command set that this command implements.

A command with subcommands should only have two fields:
cmds (of course),
and desc to briefly describe this collection of subcommands.
It may also implement doc, but GDBUI's default behavior of printing
a summary of subcommands for the command is usually sufficient.
Any other fields (args, meth, maxargs, etc) will be ignored.

=item exclude_from_completion

If this field exists, then the command will be excluded from command-line
completion.  This is useful for one-letter command synonyms, such as
"h"->"help".  To include "h" in the completions is usually mildly
confusing, especially when there are a lot of other single-letter synonyms.
This is usable in all commands, not just synonyms.

=back


=head1 CATEGORIES

Normally, when the user types 'help', she receives a summary of
every supported command.  
However, if your application has 30 or more commands, this can
result in information overload.  To manage this, you can organize
your commands into help categories

All help categories are assembled into a hash and passed to the
the default L<help_call> and L<help_args> methods.  If you don't
want to use help categories, simply pass undef.

Here is an example of how to declare a collection of help categories:

  my $helpcats = {
	  breakpoints => {
		  desc => "Commands to force the program to stop at certain points",
		  cmds => qw(break tbreak delete disable enable),
	  },
	  data => {
		  desc => "Commands to examine data",
		  cmds => ['info', 'show warranty', 'show args'],
	  }
  };

"show warranty" and "show args" are examples of how to include
subcommands in a help category.

=head1 BUGS

The Parsing/Tokeniznig should be split off into another
module, perhaps soemthing like Text::ParseWords::Cursor.

It would be nice if this module understood some sort of extended
EBNF so it could automatically
tokenize and complete commands for very complex input syntaxes.
Of course, that would be one hell of a big project...

=head1 LICENSE

Copyright (c) 2003 Scott Bronson, all rights reserved. 
This program is free software; you can redistribute it and/or modify 
it under the same terms as Perl itself.  

=head1 AUTHOR

Scott Bronson E<lt>bronson@rinspin.comE<gt>

=cut

1;
