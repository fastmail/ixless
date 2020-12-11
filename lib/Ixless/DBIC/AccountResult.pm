use 5.20.0;
use warnings;
package Ixless::DBIC::AccountResult;
# ABSTRACT: easily get resultsets bound to an accountId

use parent 'DBIx::Class';

use experimental qw(signatures postderef);

=head1 OVERVIEW

We wrote this component after forgetting one too many times to include
C<accountId> and C<isActive> in a DBIC search, which led to one very visible
bug. Mostly these methods are called via an L<Ixless::Context::WithAccount>
object, and you should probably only use this component directly if you are
writing an accountId-bound component that does I<not> use L<Ixless::DBIC::Result>,
for some reason.

This component provides two methods, C<account_rs> and
C<account_rs_including_inactive>, which automatically add C<< $self->accountId >>.
If the resultset is an L<Ixless::DBIC::Result>, the first also adds
C<< isActive => 1 >>.

=method account_rs($rs_name)

Equivalent to C<< $schema->resultset($rs_name) >>, but limits to the active
C<accountId> and, if relevant, C<isActive>.

=cut

sub account_rs ($self, $rs_name) {
  my $rs = $self->result_source->schema->resultset($rs_name)->search({
    'me.accountId' => $self->accountId,
  });

  if ($rs->result_class->isa('Ixless::DBIC::Result')) {
    $rs = $rs->search({ 'me.isActive' => 1 });
  }

  return $rs;
}

=method account_rs_including_inactive($rs_name)

Exactly like the above, but without the C<isActive> constraint.

=cut

sub account_rs_including_inactive ($self, $rs_name) {
  return $self->result_source->schema->resultset($rs_name)->search({
    'me.accountId' => $self->accountId,
  });
}

1;
