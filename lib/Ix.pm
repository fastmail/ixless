use 5.20.0;
package Ix;
# ABSTRACT: automatic HTTP interface for applications

1;

=head1 OVERVIEW

Ix is a framework for building applications using the [JMAP](http://jmap.io/)
protocol.  Ix provides abstractions for writing method handlers to handle
JMAP requests containing multiple method calls.  It also provides a mapping
layer to automatically provide JMAP's CRUD and windows query interfaces by
mapping to a L<DBIx::Class> schema.

You can probably learn most about Ix by reading the tests.  It's also much more
heavily tested than it appears, because there are test suites for internal
products built on Ix.  Remember, though:  because Ix is being changed as much
as we want, whenever we want, you can't use the tests as promises of what will
stay the same.  If we change the framework, we'll just change the tests, too.

To play with Ix, you'll need to install the prereqs that L<Dist::Zilla> will
compute, including at least one that's not on the CPAN:
[Test::PgMonger](https://github.com/fastmail/Test-PgMonger).  You'll also need
a working PostgreSQL install.
