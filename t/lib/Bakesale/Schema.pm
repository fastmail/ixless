use 5.20.0;
use warnings;
package Bakesale::Schema;
use base qw/DBIx::Class::Schema/;

__PACKAGE__->load_components(qw/+Ixless::DBIC::Schema/);

__PACKAGE__->load_namespaces(
  default_resultset_class => '+Ixless::DBIC::ResultSet',
);

__PACKAGE__->ix_finalize;

1;
