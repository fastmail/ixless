package Ixless::Multicall::Done;
# ABSTRACT: an L<Ixless::Multicall> that requires no action

use Moose;

=method execute

Simply returns the C<result_cid_pairs>.

=cut

sub execute {
  my ($self) = @_;

  return [ $self->result_cid_pairs ];
}

=attr call_ident

=cut

has call_ident => (
  is  => 'ro',
  isa => 'Str',
);

=attr result_cid_pairs

An arrayref of C<[ $result, $client_id ]> pairs representing the JMAP method
response.

=cut

has result_cid_pairs => (
  isa => 'ArrayRef',
  traits   => [ 'Array' ],
  handles  => { result_cid_pairs => 'elements' },
  required => 1,
);

with 'Ixless::Multicall';

no Moose;
__PACKAGE__->meta->make_immutable;
1;
