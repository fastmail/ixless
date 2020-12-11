use 5.20.0;
use warnings;
package Ixless::DBIC::Schema;
# ABSTRACT: a DBIx::Class schema extension for Ix

use parent 'DBIx::Class';

use experimental qw(signatures postderef);

=head1 SYNOPSIS

This package contains methods to add to your DBIC schema to make Ix aware of
them. Use it like this:

    package MyApp::Schema;
    use base qw/DBIx::Class::Schema/;

    __PACKAGE__->load_components(qw/+Ixless::DBIC::Schema/);

    __PACKAGE__->load_namespaces(
      default_resultset_class => '+Ixless::DBIC::ResultSet',
    );

    __PACKAGE__->ix_finalize;


=method ix_finalize

You must call this at the end of your schema, so that Ix can load up all of
the necessary result classes, do error checking, and set up its internal
state. The method here simply calls C<ix_finalize> on all of the loaded result
classes.

=cut

sub ix_finalize ($self) {
  my $source_reg = $self->source_registrations;
  for my $moniker (keys %$source_reg) {
    my $rclass = $source_reg->{$moniker}->result_class;
    $rclass->ix_finalize if $rclass->can('ix_finalize');
  }
}

=method deployment_statements

Any result class can contain a method called
C<ix_extra_deployment_statements>; if it does, that SQL is run when the schema
is deployed. This allows you to add custom SQL per rclass, which is especially
useful for indexes, but can be used for anything you like.

=cut

sub deployment_statements {
  my $self = shift;

  my @extra_statements = map {
    $_->result_class->ix_extra_deployment_statements
  } grep {
    $_->result_class->can('ix_extra_deployment_statements')
  } values $self->source_registrations->%*;

  return (
    $self->DBIx::Class::Schema::deployment_statements(@_),
    @extra_statements,
  );
}

=method deploy

This simply delegates to L<DBIx::Class::Schema>'s C<deploy> method. You might
override it if you want to do something different for deploying your schema.

=cut

sub deploy {
  my ($self) = shift;
  $self->storage->dbh_do(sub {
    my ($storage, $dbh) = @_;

    # Leaving this here in case we want to add anything
    # -- alh, 2017-01-12
  });
  $self->DBIx::Class::Schema::deploy(@_)
}

=method global_rs($rs_name)

=method global_rs_including_inactive($rs_name)

These methods are the counterparts to C<account_rs> and
C<account_rs_including_inactive> from L<Ixless::DBIC::AccountResult>. They are
wrappers around C<< $schema->resultset($rs_name) >>, but do not include any
accountId by default.

They are most often called via an L<Ixless::Context> object: using these methods
makes it very obvious when you intend to search the database L<across>
accounts: C<< $ctx->global_rs('Foo') >> and C<< $ctx->account_rs('Foo') >>
makes clear which is which and helps to prevent silly bugs that can occur if
you just use C<resultset> directly.

=cut

sub global_rs ($self, $rs_name) {
  my $rs = $self->resultset($rs_name);

  if ($rs->result_class->isa('Ixless::DBIC::Result')) {
    $rs = $rs->search({ 'me.isActive' => 1 });
  }

  return $rs;
}

sub global_rs_including_inactive ($self, $rs_name) {
  $self->resultset($rs_name);
}

1;
