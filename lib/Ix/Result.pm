use 5.20.0;
package Ix::Result;
# ABSTRACT: a role representing a JMAP response

use Moose::Role;
use experimental qw(signatures postderef);

use namespace::autoclean;

=head1 SYNOPSIS

An Ix::Result is a role to represent JMAP responses. It requires two methods:

=begin :list

= result_type

A string that is JMAP method name associated with this result (e.g., 'Foo/set',
'Foo/changes', 'Core/echo').

= result_arguments

A hashref of arguments in a method response.

=end :list

There are two implementations of this role provided here.

=cut

requires 'result_type';
requires 'result_arguments';

=head2 Ix::Result::Generic

The most basic implementation you could imagine.

=cut

package Ix::Result::Generic {

  use Moose;
  use MooseX::StrictConstructor;
  use experimental qw(signatures postderef);

  use namespace::autoclean;

  has result_type => (is => 'ro', isa => 'Str', required => 1);
  has result_arguments => (
    is  => 'ro',
    isa => 'HashRef',
    required => 1,
  );

  with 'Ix::Result';
};

=head2 Ix::Result::FoosSet

This represents a Foo/set method response. It has a few additional accessor
methods:

=for :list
* accountId
* old_state
* new_state
* created
* updated
* destroyed
* not_created
* not_updated
* not_destroyed

=cut

package Ix::Result::FoosSet {
# ABSTRACT: a result representing a Foo/set method response.

  use Moose;
  use MooseX::StrictConstructor;
  use experimental qw(signatures postderef);

  use namespace::autoclean;

  has accountId   => (is => 'ro', isa => 'Str', required => 1);

  has result_type => (is => 'ro', isa => 'Str', required => 1);

  has result_arguments => (
    is => 'ro',
    lazy => 1,
    default => sub ($self) {
      my %prop = (
        accountId => $self->accountId,
        oldState => $self->old_state,
        newState => $self->new_state,

        # 1. probably we should map the values here through a packer
        # 2. do we need to include empty ones?  spec is silent
        created   => $self->created,
        updated   => $self->updated,
        destroyed => $self->destroyed,
      );

      for my $p (qw(created updated destroyed)) {
        my $m = "not_$p";
        my $errors = $self->$m;

        $prop{"not\u$p"} = {
          map {; $_ => $errors->{$_}->result_arguments } keys $errors->%*
        };
      }

      return \%prop;
    },
  );

  has old_state => (is => 'ro');
  has new_state => (is => 'ro');

  has created => (is => 'ro');
  has updated => (is => 'ro');
  has destroyed => (is => 'ro');

  has not_created => (is => 'ro');
  has not_updated => (is => 'ro');
  has not_destroyed => (is => 'ro');

  with 'Ix::Result';
};

1;
