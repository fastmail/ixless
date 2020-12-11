use 5.20.0;
package Ixless::Processor;
# ABSTRACT: do stuff with requests

use Moose::Role;
use experimental qw(signatures postderef);

use Safe::Isa;
use Try::Tiny;
use Time::HiRes qw(gettimeofday tv_interval);

use namespace::autoclean;

=head1 OVERVIEW

This is a Moose role for building processors (the central component of
L<Ixless::App>s). An C<Ixless::Processor> requires four methods:

=for :list
* file_exception_report($ctx, $exception)
* context_from_plack_request($request, $arg = {})

=cut

requires 'file_exception_report';

requires 'context_from_plack_request';

=attr behind_proxy

If true, Ixless::App will wrap itself in L<Plack::Middleware::ReverseProxy>.

=cut

has behind_proxy => (
  is  => 'rw',
  isa => 'Bool',
  default => 0,
);

1;
