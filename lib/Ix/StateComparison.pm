use 5.20.0;
use warnings;
package Ix::StateComparison;
# ABSTRACT: a tiny class for comparing states

use experimental qw(signatures postderef);

sub in_sync ($class) { bless \do { my $x = 1 }, $class }
sub bogus   ($class) { bless \do { my $x = 2 }, $class }
sub resync  ($class) { bless \do { my $x = 3 }, $class }
sub okay    ($class) { bless \do { my $x = 4 }, $class }

sub is_in_sync ($self) { return $$self == 1 }
sub is_bogus   ($self) { return $$self == 2 }
sub is_resync  ($self) { return $$self == 3 }
sub is_okay    ($self) { return $$self == 4 }

1;

__END__

=head1 SYNOPSIS

This class represents the thing you get back from  C<ix_compare_state> in
L<Ix::DBIC::Result>.

    my $cmp = $rclass->ix_compare_state($old_state, $new_state);

Such an object has has exactly four useful methods:

=begin :list

= $cmp->is_in_sync()

The old and new states are the same.

= $cmp->is_bogus()

Something strange happened: the old state doesn't even make sense.

= $cmp->is_resync()

The old state is old enough that the client must resync entirely.

= $cmp->is_okay()

Anything else; processing can continue normally.

=end :list

To create a StateComparison instance (which you will need to do if you
implement your own C<ix_compare_state> method), use the following class
methods:

=for :list
* Ix::StateComparison->in_sync
* Ix::StateComparison->bogus
* Ix::StateComparison->resync
* Ix::StateComparison->okay
