use 5.20.0;
package Ix::App::JMAP;
# ABSTRACT: an Ix::App for JMAP processors

use Moose::Role;
use experimental qw(signatures postderef);

use Params::Util qw(_ARRAY0);
use Try::Tiny;

use namespace::autoclean;

with 'Ix::App';

=head1 OVERVIEW

This is a Moose::Role which is just an L<Ix::App> whose C<_core_request>
method is designed for JMAP. It only accepts JSON requests, passes them into
C<handle_calls> on an C<Ix::Context> object, then encodes the JSON on the way
out. Easy peasy.

=cut

sub _core_request ($self, $ctx, $req) {
  my $payload = try { $self->decode_json( $req->raw_body ); };

  unless ($payload) {
    return [
      400,
      [
        'Content-Type', 'application/json; charset=utf-8',
      ],
      [ '{"error":"could not decode request"}' ],
    ];
  }

  my $jmap_req  = _ARRAY0($payload)
                ? { methodCalls => $payload }
                : $payload;

  my $calls = $jmap_req->{methodCalls};
  $req->env->{'ix.transaction'}{jmap}{calls} = $calls;
  my $result  = $ctx->handle_calls($calls, { no_implicit_client_ids => 1 });
  my $struct  = _ARRAY0($payload)
              ? $result->as_triples
              : { methodResponses => $result->as_triples };
  my $json    = $self->encode_json($struct);

  return [
    200,
    [
      'Content-Type', 'application/json; charset=utf-8',
    ],
    [ $json ],
  ];
}

1;
