use v5.24.0;
package Ix::JMAP::SentenceCollection;
# ABSTRACT: an easy way to build up results

use Moose;

use experimental 'signatures';

with 'JMAP::Tester::Role::SentenceCollection';

=head1 OVERVIEW

This is an implementation of L<JMAP::Tester::Role::SentenceCollection>.
It's used internally in the JMAP processor to build up a response before
returning it.

=attr sentence_broker

The L<Ix::JMAP::SentenceBroker> associate with the collection.

=cut

use Ix::JMAP::SentenceBroker;
sub sentence_broker {
  state $BROKER = Ix::JMAP::SentenceBroker->new;
}

# [ [ $result, $cid ], ... ]
has result_client_id_pairs => (
  reader  => '_result_client_id_pairs',
  default => sub {  []  },
);

=method results

Returns a list of only the C<$result>s from C<items>.

=cut

sub results ($self) {
  map {; $_->[0] } $self->_result_client_id_pairs->@*;
}

=method has_errors

Returns 1 if any of the results in the collection is an L<Ix::Error>.

=cut

sub has_errors {
  ($_->[0]->does('Ix::Error') && return 1) for $_[0]->_result_client_id_pairs;
  return;
}

=method result($n)

Return the C<$n>th result from the collection. Throws an exception if there is
no such result.

=cut

sub result ($self, $n) {
  Carp::confess("there is no result for index $n")
    unless my $pair = $self->_result_client_id_pairs->[$n];
  return $pair->[0];
}

=method items

Returns a list of C<[ $result, $client_id ]> pairs.

=cut

sub items ($self) { $self->_result_client_id_pairs->@* }

=method add_items($items)

Push some items C<[ $result, $client_id ]> pairs onto the colleciton.

=cut

sub add_items ($self, $items) {
  push $self->_result_client_id_pairs->@*, @$items;
  return;
}

no Moose;

1;

=head1 SEE ALSO

=for :list
* L<JMAP::Tester>
