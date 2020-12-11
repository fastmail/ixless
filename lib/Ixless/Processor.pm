use 5.20.0;
package Ixless::Processor;
# ABSTRACT: do stuff with requests

use Moose::Role;
use experimental qw(signatures postderef);

use Safe::Isa;
use Try::Tiny;
use Time::HiRes qw(gettimeofday tv_interval);

use namespace::autoclean;

=head1 OVERVIEW

This is a Moose role for building processors (the central component of
L<Ixless::App>s). An C<Ixless::Processor> requires four methods:

=for :list
* file_exception_report($ctx, $exception)
* schema_class
* connect_info
* context_from_plack_request($request, $arg = {})

=cut

requires 'file_exception_report';

requires 'schema_class';

requires 'connect_info';

requires 'context_from_plack_request';

=attr behind_proxy

If true, Ixless::App will wrap itself in L<Plack::Middleware::ReverseProxy>.

=cut

has behind_proxy => (
  is  => 'rw',
  isa => 'Bool',
  default => 0,
);

=method get_database_defaults

Returns an arrayref of default strings to use for the database connection.
(These are eventually passed as the C<on_connect_do> argument to the schema's
C<connect> method.)

=cut

sub get_database_defaults ($self) {
  my @defaults = ( "SET TIMEZONE TO 'UTC'" );

  if ($self->can('database_defaults')) {
    push @defaults, $self->database_defaults;
  }

  return \@defaults;
}

=method schema_connection

Calls C<< $self->schema_class->connect >>. By default, this includes
C<auto_savepoint> and C<quote_names>.

=cut

sub schema_connection ($self) {
  $self->schema_class->connect(
    $self->connect_info,
    {
      on_connect_do  => $self->get_database_defaults,
      auto_savepoint => 1,
      quote_names    => 1,
    },
  );
}

1;
