use strict;
use warnings;
use experimental qw(postderef signatures);
package Bakesale::Schema::Result::User;
use base qw/DBIx::Class::Core/;

use Ixless::Validators qw(enum);

__PACKAGE__->load_components(qw/+Ixless::DBIC::Result/);

__PACKAGE__->table('users');

__PACKAGE__->ix_add_columns;

__PACKAGE__->ix_add_properties(
  username    => { data_type => 'istring' },
  status      => { data_type => 'string', validator => enum([ qw(active okay whatever) ]) },
  ranking     => { data_type => 'integer', is_virtual => 1 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->ix_add_unique_constraint(
  [ qw(username) ],
);

sub ix_extra_deployment_statements {
  return (
    'CREATE UNIQUE INDEX users_username_lower ON users ("isActive", lower(username))',
  );
}

sub ix_account_type { 'generic' }

sub ix_type_key { 'User' }

sub ix_is_account_base { 1 }

sub ix_default_properties ($self, $ctx) {
  return {
    status => 'active',
  },
}

sub ix_create_error ($self, $ctx, $error, $args) {
  my $input = $args->{input};
  my $rec = $args->{rec};

  if ($error =~ /duplicate key value/) {
    if ($rec->{username} eq 'nobody') {
      # Anyone can create nobody even if they already exist
      my $nobody = $ctx->schema->resultset('User')->single({
        username => 'nobody',
      });

      # Trick Ix into thinking the user input matches everything on the row
      # (except the id) so they only get the id back. They already know
      # the username, and this simulates them not having access to the rest
      # of the user
      my %is_virtual = map {;
        $_ => 1
      } $nobody->ix_virtual_property_names;

      $input->{$_} = $nobody->$_ for grep {;
        ! $is_virtual{$_}
      } keys $nobody->ix_property_info->%*;

      delete $input->{id};

      return $nobody;
    } elsif ($rec->{username} eq 'kaboom') {
      # Let Ix handle this duplicate key error
      return ();
    }

    return (
      undef,
      $ctx->error(alreadyExists => {
        description => "that username already exists during create",
      }),
    );
  }

  return ();
}

sub ix_update_error ($self, $ctx, $error, $args) {
  my $input = $args->{input};
  my $row = $args->{row};

  if ($error =~ /duplicate key value/) {
    # Trying to update to be 'nobody', pretend there were no updates
    if ($row->username eq 'nobody') {
      my $nobody = $ctx->schema->resultset('User')->single({
        username => 'nobody',
      });

      return $Ixless::DBIC::ResultSet::SKIPPED;
    } elsif ($row->username eq 'kaboom') {
      # Let Ix handle this duplicate key error
      return ();
    }

    return (
      undef,
      $ctx->error(alreadyExists => {
        description => "that username already exists during update",
      }),
    );
  }

  return ();
}

sub ix_create_check ($self, $ctx, $arg) {
  # Super contrived test - change 'okay' to 'active', used to make sure
  # behind-the-scenes changes during create bubble up to the response
  # seen by the caller
  if ($arg->{status} && $arg->{status} eq 'okay') {
    $arg->{status} = 'active';
  }

  return;
}

sub ix_changes_check ($self, $ctx, $arg) {
  # Not allowed to get more than 5 updates
  if ($arg->{limit} && $arg->{limit} > 5) {
    return $ctx->error(overLimit => {
      description => "Requested too many updates"
    });
  }

  return;
}

sub ix_get_extra_search ($self, $ctx, $arg = {}) {
  my ($cond, $attr) = $self->SUPER::ix_get_extra_search($ctx);

  if (grep {; $_ eq 'ranking' } $arg->{properties}->@*) {
    $attr->{'+columns'} ||= {};
    $attr->{'+columns'}{ranking} = \q{(
      SELECT COUNT(*)+1 FROM users s
        WHERE s."modSeqCreated" < me."modSeqCreated" AND s."dateDestroyed" IS NULL AND s."accountId" = me."accountId"
    )};
  }

  return ($cond, $attr);
}

sub ix_postprocess_create ($self, $ctx, $rows) {
  my $dbh = $ctx->schema->storage->dbh;

  # Fill in ranking on create response
  my $query = q{
    SELECT COUNT(*)+1 FROM users s
      WHERE s.id != ? AND s."dateDestroyed" IS NULL AND s."accountId" = ?
  };

  for my $r (@$rows) {
    my $res = $dbh->selectall_arrayref($query, {}, $r->{id}, $ctx->accountId);
    $r->{ranking} = $res->[0]->[0];
  }

  return;
}

sub ix_query_sort_map {
  return {
    username => { },
    status   => { },
    ranking  => { },
  };
}

sub ix_query_filter_map {
  return {
    username => { },
    status   => { },
    ranking  => { },
  };
}

sub ix_query_joins { () }

sub ix_query_check { }
sub ix_query_changes_check { }

sub ix_query_enabled { 1 }

1;
