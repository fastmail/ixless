use 5.20.0;
package Ixless::Context;
# ABSTRACT: access information from a bunch of places
#           Where did you come from, where did you go?

use Moose::Role;
use experimental qw(signatures postderef);

use Ixless::Error;
use Ixless::Result;
use Safe::Isa;

use namespace::autoclean;

=head1 OVERVIEW

An object that does C<Ixless::Context> is passed as an argument to nearly every Ix
method.  It contains, well, I<context> for a given request, as well as
accessors to a bunch of things you might need in all sorts of places: the
schema, methods for reporting errors, information about the results so far,
and so on.

It requires two methods:

=begin :list

= with_account

A means for binding this object to a particular JMAP account.

= is_system

Whether or not this context is specially privileged. System contexts are often
allowed to bypass certain kinds of permissions checks that normal contexts
cannot.

=end :list

=cut

requires 'with_account'; # $dctx = $ctx->with_account(type => optional_id)
requires 'is_system';

=attr root_context

This object's "root context." This abstraction is not particularly great, but
we haven't come up with anything better yet. Often, you will make one kind of
context from another: a C<with_account> object from one without, for example.
Those objects need some way of referring back to the original context, and
they do so through the C<root_context> attribute. Often, the root context
provides a bunch of delegates, so that you can still get a C<< ->schema >>
from some descendant context.

=cut

sub root_context ($self) { $self }

=attr schema

A handle to an C<Ixless::DBIC::Schema> object. This is the normal way of accessing
the database from inside your application.

=method global_rs

=method global_rs_including_inactive

These are delegates to the methods of the same name in C<< $self->schema >>.

=cut

has schema => (
  is   => 'ro',
  required => 1,
  handles  => [ qw( global_rs global_rs_including_inactive ) ],
);

=attr processor

An C<Ixless::Processor> that's used to C<handle_calls> made on this context.

=cut

has processor => (
  is   => 'ro',
  does => 'Ixless::Processor',
  required => 1,
);

# Internal; used to hold all the JMAP creation IDs stored so far in this call.
has created_ids => (
  is => 'ro',
  reader   => '_created_ids',
  init_arg => undef,
  default  => sub {  {}  },
);

=attr call_info

An arrayref of C<[ $method_name, $info ]> pairs. This is used by the processor
to include things like timing information for logging.

=cut

has call_info => (
  is => 'ro',
  traits   => [ 'Array' ],
  handles  => {
    _add_call_info => 'push',
  },

  default => sub { [] },
);

=method record_call_info($call, $info)

Add some diagnostic information for a method call.

=cut

sub record_call_info ($self, $call, $info) {
  $self->_add_call_info([ $call, $info ]);
}

=method log_created_id($type, $creation_id, $id)

This is used internally to keep track of JMAP creation ids, so that later we
can resolve references to them.

=cut

sub log_created_id ($self, $type, $creation_id, $id) {
  my $reg = ($self->_created_ids->{$type} //= {});

  if ($reg->{$creation_id}) {
    $reg->{$creation_id} = \undef;
  } else {
    $reg->{$creation_id} = $id;
  }

  return;
}

=method get_created_id($type, $creation_id)

This is used internally to resolve references to objects previously created
during this call. Returns the id, if it's found, otherwise throws an exception.

=cut

sub get_created_id ($self, $type, $creation_id) {
  my $id = $self->_created_ids->{$type}{$creation_id};

  $self->error(duplicateCreationId => {})->throw
    if ref $id && ! defined $$id;

  return $id;
}

has result_accumulator => (
  init_arg  => undef,
  predicate => 'is_handling_calls',
  reader    => '_result_accumulator',
);

=method results_so_far

This is used during a single request to access the
L<Ixless::JMAP::SentenceCollection> that's accumulating the results.

=cut

sub results_so_far ($self) {
  $self->internal_error("tried to inspect results outside of request")->throw
    unless $self->is_handling_calls;

  return $self->_result_accumulator;
}

=method handle_calls($calls, $arg)

A wrapper around the processor's C<handle_calls>. Returns an
L<Ixless::JMAP::SentenceCollection>.

=cut

sub handle_calls ($self, $calls, $arg = {}) {
  $self->processor->handle_calls($self, $calls, $arg);
}

=method process_request($calls, $arg)

A wrapper around the processor's C<process_request>. Returns an arrayref of
method responses.

=cut

sub process_request ($self, $calls) {
  $self->processor->process_request($self, $calls);
}

=method logged_exception_guids

A list of exception GUIDs logged by the current request.

=method log_exception_guid($guid)

Add a GUID to the list of exception GUIDs for this request.

=cut

has logged_exception_guids => (
  init_arg => undef,
  lazy     => 1,
  default  => sub {  []  },
  traits   => [ 'Array' ],
  handles  => {
    logged_exception_guids => 'elements',
    log_exception_guid     => 'push',
  },
);

=method report_exception($exception)

This just delegates to the processor's C<file_exception_report> method and
logs the exception's GUID.

=cut

sub report_exception ($ctx, $exception) {
  # Ixless::Error::Internals are created after we've already reported an
  # exception, so don't throw them again
  return $exception->report_guid if $exception->$_isa('Ixless::Error::Internal');

  my $guid = $ctx->processor->file_exception_report($ctx, $exception);
  $ctx->log_exception_guid($guid);
  return $guid;
}

=method error($ctx, $type, $prop = {}, $ident = undef, $payload = undef)

A convenience method for generating an L<Ixless::Error::Generic> object. If you
pass C<$ident>, this method also wraps it in an ExceptionWrapper and calls
C<report_exception>.

=cut

sub error ($ctx, $type, $prop = {}, $ident = undef, $payload = undef) {
  my $report_guid;
  if (defined $ident) {
    my $report = Ixless::ExceptionWrapper->new({
      ident => $ident,
      ($payload ? (payload => $payload) : ()),
    });

    $report_guid = $ctx->report_exception($report);
  }

  Ixless::Error::Generic->new({
    error_type => $type,
    properties => $prop,
    ($report_guid ? (report_guid => $report_guid) : ()),
  });
}

=method internal_error($ident, $payload = undef)

Just like C<error>, but C<$ident> is required, and instead generates an
L<Ixless::Error::Internal>.

=cut

sub internal_error ($ctx, $ident, $payload = undef) {
  my $report = Ixless::ExceptionWrapper->new({
    ident => $ident,
    ($payload ? (payload => $payload) : ()),
  });

  my $report_guid = $ctx->report_exception($report);

  Ixless::Error::Internal->new({
    error_ident => $ident,
    report_guid => $report_guid,
  });
}

=method result($type, $properties = {})

A convenience method for generating an L<Ixless::Result::Generic>.

=cut

sub result ($ctx, $type, $prop = {}) {
  Ixless::Result::Generic->new({
    result_type       => $type,
    result_arguments => $prop,
  });
}

=method result_without_accountid($type, $properties = {})

Just like C<result>, but C<WithAccount> contexts will not include an
C<accountId> in the properties by default. This is useful because some JMAP
methods are defined to return an empty JSON object.

=cut

sub result_without_accountid ($ctx, $type, $prop = {}) {
  return $ctx->result($type, $prop);
}

=method may_call($method)

Whether or not this context is allowed to call C<$method>.

=cut

sub may_call { 1 }

1;
