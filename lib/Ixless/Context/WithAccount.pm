use 5.20.0;
package Ixless::Context::WithAccount;
# ABSTRACT: an Ixless::Context, bound to a single account

use Moose::Role;
use experimental qw(signatures postderef);

use Ixless::Error;
use Ixless::Result;

use Ixless::AccountState;

use Try::Tiny;

use namespace::autoclean;

=head1 OVERVIEW

This is a Moose role representing an L<Ixless::Context> object that's bound to a
single account. Most operations in Ix are done on a single account, and thus
done with a C<WithAccount> context object. When a request comes in to an
C<Ixless::App>, we build a context for a given accountId, and then all of the
methods are bound to that context. In addition to access control, a
WithAccount context handles record-keeping of modseqs and state strings for an
account.

Implementations are required to implement two methods:

=for :list
* account_type
* accountId

=cut

requires 'account_type';
requires 'accountId';

=attr root_context

=cut

has root_context => (
  is     => 'ro',
  does   => 'Ixless::Context',
  required => 1,
  handles  => [ qw(
    schema
    processor
    global_rs
    global_rs_including_inactive

    get_created_id log_created_id

    log_exception_guid
    report_exception

    record_call_info
    _save_states

    error
    internal_error

    results_so_far

    may_call
  ) ],
);

has _txn_level => (
  is => 'rw',
  isa => 'Int',
  init_arg => undef,
  default => 0,
);

=attr state

An L<Ixless::AccountState> object.

=cut

has state => (
  is => 'rw',
  isa => 'Ixless::AccountState',
  lazy => 1,
  builder => '_build_state',
  predicate => '_has_state',
);

sub _build_state ($self) {
  Ixless::AccountState->new({
    context      => $self,
    account_type => $self->account_type,
    accountId    => $self->accountId,
  });
}

=method txn_do($code)

A wrapper around C<txn_do> from L<DBIx::Class>. What this does is:

=begin :list

* increment our transaction depth
* localize our copy of the pending states
* Run the transaction
* If it succeeds, we copy out the states that actually need changing
  and ship them up to our outer scope. This ensures that we don't
  record state changes in internal calls to ix_set if something fails
  somewhere along the way.
* decrement our transaction depth. If depth reaches 0, that means we're
  at the start of the transaction and we need to commit state changes

=end :list

This should probably only be used by C<ix_set()> and any calls it makes
internally that may try to bump state (generally, anything that may lead
to a nested ix_set).

=cut

sub txn_do ($self, $code) {
  return $self->schema->txn_do(sub {
    if (
         $self->_txn_level == 0
      && $self->_has_state
    ) {
      # We should *NOT* have gotten any state information before starting
      # a brand new transaction tree. If so, something is wrong.
      require Carp;
      Carp::confess("We already have state before starting a transaction?!");
    }

    # Start of a tree? Localize state so it goes away when we're done
    local $self->{state} = $self->_build_state if $self->_txn_level == 0;

    my $state = $self->state;

    my @rv;
    my $inner = { $state->_pending_states->%* };

    {
      # Localize txn level and pending states and  for next ix_* calls that
      # may happen
      local $self->{_txn_level} = $self->_txn_level + 1;
      local $state->{_pending_states} = $inner;

      @rv = $code->();
    }

    # Copy any actually bumped states up
    for my $k (keys %$inner) {
      $state->_pending_states->{$k} = $inner->{$k};
    }

    # Are we the start of this tree? Commit the state changes if any
    if ($self->_txn_level == 0) {
      try {
        $state->_save_states;
      } catch {
        my $error = $_;

        if ($error =~ /unique.*states_pkey/i) {
          $self->error('tryAgain' => {
            description => "blocked by another client",
          })->throw;
        }

        # What even happened?
        die $error;
      };
    }

    return @rv;
  });
}

=method process_request($calls)

=cut

sub process_request ($self, $calls) {
  $self->processor->process_request($self, $calls);
}

=method account_rs($rs_name)

Just like C<< $self->schema->resultset($rs_name) >>, but ensures that the
resultset only contains active rows matching our accountId. See also
L<Ixless::DBIC::AccountResult>.

=cut

sub account_rs ($self, $rs_name) {
  my $rs = $self->schema->resultset($rs_name)->search({
    'me.accountId' => $self->accountId,
  });

  if ($rs->result_class->isa('Ixless::DBIC::Result')) {
    $rs = $rs->search({ 'me.isActive' => 1 });
  }

  return $rs;
}

=method account_rs_including_inactive($rs_name)

Just like C<account_rs>, but without the C<isActive> constraint.  See also
L<Ixless::DBIC::AccountResult>.

=cut

sub account_rs_including_inactive ($self, $rs_name) {
  $self->schema->resultset($rs_name)->search({
    'me.accountId' => $self->accountId,
  });
}

=method with_account($account_type, $accountId)

This is a no-op and returns C<$self> unless the type and accountId do not
match our own, in which case it throws an internal error.

=cut

sub with_account ($self, $account_type, $accountId) {
  if (
    $account_type eq $self->account_type
    &&
    ($accountId // $self->accountId) eq $self->accountId
  ) {
    return $self;
  }

  $self->internal_error("conflicting recontextualization")->throw;
}

=method result($type, $properties = {})

A convenience method for generating an L<Ixless::Result::Generic>. If
C<$properties> contains an C<accountId> that does not match our own, generates
an internal error. All results will include our accountId.

=cut

sub result ($self, $type, $prop = {}) {
  $self->internal_error("got conflicting accountIds")
    if (exists $prop->{accountId} && $prop->{accountId} ne $self->accountId);

  $prop->{accountId} = $self->accountId;
  return $self->root_context->result($type, $prop);
}

=method result_without_accountid($type, $properties = {})

Just like C<result>, but without checking the properties and without
C<accountId> in the returned result.

=cut

sub result_without_accountid ($self, $type, $prop={}) {
  return $self->root_context->result($type, $prop);
}

1;
