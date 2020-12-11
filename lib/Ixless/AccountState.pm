use 5.20.0;
use warnings;
package Ixless::AccountState;
# ABSTRACT: bookkeeping for JMAP state strings

use Moose;
use MooseX::StrictConstructor;
use experimental qw(signatures postderef);

use namespace::clean;

# XXX: this whole class needs rethinking without dbic

=head1 OVERVIEW

This class is responsible for keeping track of JMAP state strings for an
account. Every L<Ixless::DBIC::Result> row has associated accountId,
modSeqCreated, and modSeqChanged columns. The state strings for these object
types are tracked in a separate table, which is represented by an
L<Ixless::DBIC::StatesResult> rclass.

When modifying a result row, the context object calls out to an AccountState
object to fill in modSeqCreated or modSeqChanged attributes, and to ensure
that the modseqs in the states table are modified as needed.

=attr context

=attr account_type

=attr accountId

=cut

has context => (
  is => 'ro',
  required => 1,
  weak_ref => 1,
);

has [ qw(account_type accountId) ] => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has _pending_states => (
  is  => 'rw',
  init_arg => undef,
  default  => sub {  {}  },
);

sub _pending_state_for ($self, $type) {
  return $self->_pending_states->{$type};
}

=method state_for($type)

Returns the current state for a given type.

=cut

sub state_for ($self, $type) {
  my $pending = $self->_pending_state_for($type);
  return $pending if defined $pending;
  return "0";
}

=method lowest_modseq_for($type)

=method highest_modseq_for($type)

These methods are accessors for the relevant fields in the states row for
C<$type>.

=cut

sub lowest_modseq_for ($self, $type) {
  return 0;
}

sub highest_modseq_for ($self, $type) {
  return 0;
}

=method ensure_state_bumped($type)

This is called internally by L<Ixless::DBIC::ResultSet> to bump the state for a
given type. Internally, this keeps track of pending states and ensures that
the state is only bumped once per transaction.

=cut

sub ensure_state_bumped ($self, $type) {
  return if defined $self->_pending_state_for($type);
  $self->_pending_states->{$type} = $self->next_state_for($type);
  return;
}

=method next_state_for($type)

This is used by L<Ixless::DBIC::ResultSet> to fill in modSeqCreated or
modSeqChanged values on result rows. It returns the current state + 1 if no
changes are pending, and the pending state if one exists.

=cut

sub next_state_for ($self, $type) {
  my $pending = $self->_pending_state_for($type);
  return $pending if $pending;
  return 0;
}

sub _save_states ($self) {
  my $pend = $self->_pending_states;
  $self->_pending_states({});
  return $pend;
}

1;
