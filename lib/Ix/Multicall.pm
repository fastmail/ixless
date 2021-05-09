package Ix::Multicall;
# ABSTRACT: an abstraction representing a collection of calls

use Moose::Role;

=head1 OVERVIEW

This is a Moose role representing a combination of calls which is actually
performed as a single call. This allows an Ix::App to optimize client calls
if desired.

=method execute

=method call_ident

A JMAP method name for this kind of call (e.g., I<Foo/multiget>).

=cut

requires 'execute';
requires 'call_ident';

no Moose::Role;
1;
