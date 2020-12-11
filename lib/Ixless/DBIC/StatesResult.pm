use 5.20.0;
use warnings;
package Ixless::DBIC::StatesResult;
# ABSTRACT: the DBIC result for your states

use parent 'DBIx::Class';

use experimental qw(signatures postderef);

=head1 SYNOPSIS

This is the DBIC result class for all of your application's JMAP state strings.
Probably you can just copy and paste this exactly.

    package MyApp::Schema::Result::State;
    use base qw/DBIx::Class::Core/;

    __PACKAGE__->load_components(qw/+Ixless::DBIC::StatesResult/);
    __PACKAGE__->table('states');
    __PACKAGE__->ix_setup_states_result;

=method ix_setup_states_result

Does what it says on the tin. Adds four columns: accountId, type,
lowestModSeq, and highestModSeq.

=cut

sub ix_setup_states_result ($class) {
  $class->add_columns(
    accountId     => { data_type => 'uuid' },
    type          => { data_type => 'text' },
    lowestModSeq  => { data_type => 'integer' },
    highestModSeq => { data_type => 'integer' },
  );

  $class->set_primary_key(qw( accountId type ));
}

1;
