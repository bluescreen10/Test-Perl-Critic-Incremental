=head1 NAME

Test::Perl::Critic::Incremental - Enforce Best Practices incrementally

=head1 SYNOPSIS

Test one file:

  use Test::Perl::Critic::Incremental;
  use Test::More tests => 1;
  critic_ok($file);

Or test all files in one or more directories:

  use Test::Perl::Critic::Incremental;
  all_critic_ok($dir_1, $dir_2, ... );

Or test all files in a distribution:

  use Test::Perl::Critic;
  all_critic_ok();

=head1 DESCRIPTION

This module is designed to help incrementally improving legacy code. Running
L<Test::Perl::Critic> on a legacy application can be overwhelming and a lot of
errors are to be expected. It can also become challenging if you want to add
more L<Perl::Critic> policies to an existent codebase.

This module will run for the first time and record all Perl::Critic's violation
in a file and every failing test case as result of the violations will be marked
as TODO. The next time it runs it will compare violations to the previous run
and if a particular file has more violations test will fail, if it has less or 
equal violations test will fail but test will be mark as TODO, finally if it 
has no violations test will pass.

Essentially what this module forces you to improve your code over time.

=cut

package Test::Perl::Critic::Incremental;

use strict;
use warnings;
use English qw(-no_match_vars);
use Test::Builder qw();
use Perl::Critic qw();
use Perl::Critic::Violation qw();
use Perl::Critic::Utils;
use Storable qw(retrieve store);
use Digest::SHA1;

our $VERSION = 0.01;

my $test;
my $critic;
my $history;
my $history_file = '.perlcritic-history';
my $current_violations;

my $first_run;
my $skip_file_pattern;
my $use_sum;

=head1 CONFIGURATION

Test::Perl::Critic::Incremental supports passing configuration parameters to
L<Perl::Critic> in the same way that L<Test::Perl::Critic> does, that means via
the C<use> pragma or via C<Test::Perl::Critic::Incremental->import()> to see
more options please refer to L<Test::Perl::Critic> documentation.

It also supports two propietary configuration parameters that are not passed to
L<Perl::Critic> those are:

=over

=item -skip_files_like

This allow you to provide a filter for source file names, this filter comes into
play when you call <all_critic_ok> function. For example:

  use Test::Perl::Critic::Incremental ( -skip_files_like => qr/\.pl$/ );
  all_critic_ok();

  # or

  use Test::Perl::Critic::Incremental ( -skip_files_like => 'BadClass' );
  all_critic_ok();

=item -use_checksum

As Test::Perl::Critic::Incremental criticizes source code files it will not only
record violations but also a checksum of the file. if you set C<-use_checksum>
to a true value it will skip files that haven't change since last run. This has
two benefits. First speed as it doesn't need to analyze files again. Second and
most important it allows you tweak L<Perl::Critic> policies and those apply to
only to modified files. By default it is not activated.

=item -history_file

By default Test::Perl::Critic::Incremental uses F<.perlcritic-history> to store
violations encountered by L<Perl::Critic> in your code files. This parameter
allows to so change the location and/or file name.

=back

=cut

sub import {
    my ( $class, %args ) = @_;
    my $caller = caller;

    {
        no strict 'refs';    ## no critic qw(ProhibitNoStrict)
        *{ $caller . '::critic_ok' }     = \&critic_ok;
        *{ $caller . '::all_critic_ok' } = \&all_critic_ok;
    }

    $skip_file_pattern = delete $args{'-skip_files_like'};
    $use_sum           = delete $args{'-use_checksum'};
    $history_file = delete $args{'-history_file'} if $args{'-history_file'};

    $critic = Perl::Critic->new(%args);
    $test   = Test::Builder->new;

    $history   = _read_history( $history_file );
    $first_run = not defined $history;

    Perl::Critic::Violation::set_format( $critic->config->verbose );
    $test->level(2);
}

=head1 EXPORTED FUNCTIONS

=head2 critic_ok( $file [, $test_name ] )

Okays the test if Perl::Critic does not find any violations in C<$file>. If it
does, the violations will be reported in the test diagnostics. The optional
second argument is the name of test, which defaults to "Perl::Critic test for
C<$file>".

If you use this form, you should emit your own L<Test::More> plan first.

=cut

sub critic_ok {
    my ( $file, $test_name ) = @_;

    $test->croak("$file does not exist") if not -f $file;
    $test_name ||= "Perl::Critic test for $file";

    eval {
        my $sum = _calculate_sum($file);
        my $file_history = $history->{$file} || { violations => [], sum => '' };

        my @violations;
        my $old_count;

        if ( $use_sum and $file_history->{sum} eq $sum ) {
            @violations = @{ $file_history->{violations} };
            $old_count  = scalar @violations;
        }

        else {
            @violations = $critic->critique($file);
            @violations = map { $_->to_string } @violations;
            $old_count  = scalar @{ $file_history->{violations} };
        }

        my $new_count = scalar @violations;

        $current_violations->{$file} = {
            violations => \@violations,
            sum        => $sum,
        };

        if ($new_count) {
            my $delta = $old_count - $new_count;

            $test->todo_start("fixed $delta violations!") if $delta >= 0;
            $test->todo_start('No history file') if $first_run;
            $test->ok( 0, $test_name );
            $test->diag( "\t" . join( "\t", @violations ) );
            $test->todo_end if $first_run or $delta >= 0;
            return;
        }

        else {
            $test->ok( 1, $test_name );
        }
    };

    if ($EVAL_ERROR) {
        $test->ok( 0, "Perl::Critic Can't process $file: $EVAL_ERROR" );
    }
}

=item all_critic_ok( [ @directories ] )

Runs C<critic_ok()> for all Perl files beneath the given list of 
C<@directories>. If C<@directories> is empty or not given, this function tries
to find all Perl files in the C<@INC> directories. If the C<@INC> directories
does not exist, then it tries the C<@INC> directory. Returns true if all files
are okay, or false if any file fails.

This subroutine emits its own L<Test::More> plan, so you do not need to specify
an expected number of tests yourself.

A Perl file is:

=over

=item * Any file that ends in F<.PL>, F<.pl>, F<.pm>, or F<.t>

=item * Any file that has a first line with a shebang containing 'perl'

=back

=cut

sub all_critic_ok {
    my @dirs = @_;
    if ( not @dirs ) {
        @dirs = _starting_points();
    }

    my @files = Perl::Critic::Utils::all_perl_files(@dirs);

    if ($skip_file_pattern) {
        @files = grep { !/$skip_file_pattern/ } @files;
    }

    $test->level(3);
    $test->plan( tests => scalar @files );

    my $okays = grep { critic_ok($_) } @files;
    return $okays == @files;
}

sub _calculate_sum {
    my $file = shift;

    open my $fh, '<', $file or die "Can't open $file: $OS_ERROR";
    my $sum = Digest::SHA1->new->addfile($fh)->hexdigest;
    close $fh or die "Can't close $file";

    return $sum;
}

sub _starting_points {
    return @INC;
}

sub _write_history_file {
    my ( $file, $history_data ) = @_;

    store( $history_data, $file )
      or die "Can't write to $history_file: $OS_ERROR";
}

sub _read_history {
    my $file = shift;

    return unless -f $file;
    retrieve($file);
}

END {
    _write_history_file( $history_file, $current_violations )
      if $test->is_passing and $current_violations;
}

1;

__END__

=head1 BUGS

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Test-Perl-Critic-Incremental>

=head1 SEE ALSO

L<Test::Perl::Critic::Progressive>

L<Test::Perl::Critic>

L<Perl::Critic>

L<Test::More>

=head1 CREDITS

This module was greatly inspired and influenced by L<Test::Perl::Critic::Progressive> and L<Test::Perl::Critic::Incremental>. I'd also like to acknowledge Ignacio Regueiro as he did a lot of the hard work in this module.  

=head1 AUTHOR

Mariano Wahlmann <dichoso@gmail.com>

=head1 COPYRIGHT

Copyright (c) 2012 Mariano Wahlmann

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. The full text of this license
can be found in the LICENSE file included with this module.

