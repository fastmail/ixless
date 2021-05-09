use 5.20.0;
package Ix::Error;
# ABSTRACT: a throwable, failed Ix::Result

use Moose::Role;
use experimental qw(signatures postderef);

with 'Ix::Result', 'Throwable';

use namespace::autoclean;

=head1 OVERVIEW

This is a Moose role that represents a failed L<Ix::Result>, with a result
type C<error>. Implementations are required to implement C<error_type>. This
package include two implementations.

=head2 Ix::Error::Internal

This kind of error is thrown by C<Ix::App> when it catches an exception.  It's
designed so that it shows no useful information to the client: if an internal
error has happened, there's no telling what might be in C<$@>, so we don't
want to pass that on. Instead, we return a JMAP error with type
C<internalError> and a C<guid>, so that you can look up the report that's been
filed out-of-band.  An internal error object has two other useful methods on it:
C<error_ident> and C<report_guid>.

=head2 Ix::Error::Generic

This is an error that's suitable to throw for run-of-the mill JMAP errors
(invalidArguments, unknownMethod, etc.). They have a few useful methods:
C<report_guid>, C<properties>, and C<error_type>.

=cut

sub result_type { 'error' }

requires 'error_type';

package
  Ix::ExceptionWrapper {

  use Moose;
  use MooseX::StrictConstructor;
  use namespace::autoclean;

  with 'StackTrace::Auto';

  has ident => (
    is => 'ro',
    default => 'unspecified error!',
  );

  has payload => (
    is => 'ro',
    default => sub {  {}  },
  );

  __PACKAGE__->meta->make_immutable;
}

package Ix::Error::Internal {

  use Moose;
  use MooseX::StrictConstructor;
  use experimental qw(signatures postderef);

  use namespace::autoclean;

  use overload
    '""' => sub {
      return sprintf "Ix::Error::Internal(%s %s)",
        $_[0]->error_ident,
        $_[0]->report_guid;
    },
    fallback => 1;

  has error_ident => (
    is  => 'ro',
    isa => 'Str',
    required => 1,
  );

  has report_guid => (
    is  => 'ro',
    isa => 'Str',
    required => 1,
  );

  sub error_type { 'internalError' }

  sub result_arguments ($self) {
    return { type => 'internalError', guid => $self->report_guid };
  }

  with 'Ix::Error';

  __PACKAGE__->meta->make_immutable;
}

package Ix::Error::Generic {

  use Moose;
  use MooseX::StrictConstructor;
  use experimental qw(signatures postderef);

  use namespace::autoclean;

  use overload
    '""' => sub {
      if ($_[0]->has_report_guid) {
        return sprintf "Ix::Error::Generic(%s %s)",
          $_[0]->error_type,
          $_[0]->report_guid;
      }

      return sprintf "Ix::Error::Generic(%s)", $_[0]->error_type;
    },
    fallback => 1;

  sub result_arguments ($self) {
    # We're not returning the report guid here, which is probably okay, but
    # maybe let's reconsider that in the future. -- rjbs, 2016-08-12
    return { $self->properties, type => $self->error_type };
  }

  sub BUILD ($self, @) {
    Carp::confess(q{"type" is forbidden as an error property})
      if $self->has_property('type');
  }

  has report_guid => (
    is  => 'ro',
    isa => 'Str',
    predicate => 'has_report_guid',
  );

  has properties => (
    isa => 'HashRef',
    traits  => [ 'Hash' ],
    handles => { properties => 'elements', has_property => 'exists' },
  );

  has error_type => (
    is  => 'ro',
    isa => 'Str', # TODO specify -- rjbs, 2016-02-11
    required => 1,
  );

  with 'Ix::Error';

  __PACKAGE__->meta->make_immutable;
}

1;
