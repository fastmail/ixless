use 5.20.0;
package Ixless::App;
# ABSTRACT: stand up a PSGI application to handle requests from the world

use Moose::Role;
use experimental qw(signatures postderef);

use Data::GUID qw(guid_string);
use JSON::MaybeXS;
use Plack::Request;
use Try::Tiny;
use Safe::Isa;
use Plack::Util;
use Plack::Builder;
use IO::Handle;
use Time::HiRes qw(gettimeofday tv_interval);
use Plack::Middleware::ReverseProxy;
use Ixless::Util;

use namespace::autoclean;

=head1 SYNOPSIS

Here's a tiny script suitable for running with L<plackup>.

    package MyApp::App { with 'Ixless::App' }
    MyApp::App->new->to_app;

=head1 OVERVIEW

Ixless::App is a Moose role for building PSGI applications. It receives requests,
creates L<Ixless::Context> objects from them, and then passes them off to the
L<Ixless::Processor> to handle them. It also handles a bunch of other low-level
things like logging, basic error handling, etc.

=attr json_codec

Handles encoding and decoding of JSON. This provides delegates for
C<encode_json> and C<decode_json>, so you can say C<< $app->decode_json >> if
you like. Defaults to a L<JSON::MaybeXS> object.

=cut

has json_codec => (
  is => 'ro',
  default => sub {
    JSON::MaybeXS::JSON->new->utf8->allow_blessed->convert_blessed
  },
  handles => {
    encode_json => 'encode',
    decode_json => 'decode',
  },
);

=attr logger_json_codec

Just like the C<json_codec>, but used to serialize JSON for logging (the
default includes C<canonical> for easier human reading). Provides two delegates,
C<encode_json_log> and C<decode_json_log>.

=cut

has logger_json_codec => (
  is => 'ro',
  default => sub {
    JSON::MaybeXS::JSON->new->utf8->allow_blessed->convert_blessed->canonical
  },
  handles => {
    encode_json_log => 'encode',
    decode_json_log => 'decode',
  },
);

=attr processor (required)

An L<Ixless::Processor>...the most important part of any Ixless::App!

=cut

has processor => (
  is => 'ro',
  required => 1,
);

=attr access_log_enabled (default 0)

=attr access_log_fh

If access logging is enabled, the filehandle to which we'll log. Defaults to
STDERR.

=cut

has access_log_enabled => (
  is => 'rw',
  isa => 'Bool',
  default => 0,
);

has access_log_fh => (
  is => 'rw',
  isa => 'FileHandle',
  default => sub { IO::Handle->new->fdopen(fileno(STDERR), "w") },
);

=attr transaction_log_enabled (default 0)

=cut

has transaction_log_enabled => (
  is  => 'rw',
  isa => 'Bool',
  default => 0,
);

has _caches => (
  is => 'ro',
  init_arg => undef,
  default  => sub {  []  },
);

=method to_app

This is the most important method on an Ixless::App; it returns a PSGI application
(i.e., a coderef). It takes the environment, adds some information to it (an
C<ix.transaction> key), calls C<context_from_plack_request> on the processor,
caches the schema, then passes it off to C<_core_request> to do the actual
processing. If fatal errors occur during processing, it reports the exception
and returns 500.  Otherwise, it logs the result (if logging is enabled) and
returns the response from the processor.

=cut

sub to_app ($self) {
  my $app = sub ($env) {
    my $req = Plack::Request->new($env);

    my $guid = guid_string();

    my %HEADER = (
      Vary               => 'Origin',
      'Ix-Transaction-ID' => $guid,
    );

    state $transaction_number;
    $transaction_number++;
    $req->env->{'ix.transaction'} = {
      guid  => $guid,
      time  => Ixless::DateTime->now,
      htime => [ gettimeofday ],
      seq   => $transaction_number,
    };

    my $ctx;
    my $res = try {
      $ctx = $self->processor->context_from_plack_request($req, {});
      Carp::confess("could not establish context")
        unless $ctx && $ctx->does('Ixless::Context');
      $self->_core_request($ctx, $req);
    } catch {
      my $error = $_;

      # Let HTTP::Throwable pass through
      if ($error->$_can('as_psgi')) {
        return $error->as_psgi;
      }

      my $guid = $ctx ? $ctx->report_exception($error) : undef;
      unless ($guid) {
        warn "could not report exception: $error";
      }

      return [
        500,
        [
          'Content-Type', 'application/json; charset=utf-8',
        ],
        [ $self->encode_json({ error => "internal", guid => $guid }) ],
      ];
    };

    # If any of this throws an exception, we still need to respond with
    # our results because the database changes have been committed by now.
    try {
      $req->env->{'ix.transaction'}{end_htime} = [ gettimeofday ];
      $req->env->{'ix.transaction'}{elapsed_seconds} = tv_interval(
        $req->env->{'ix.transaction'}{htime},
        $req->env->{'ix.transaction'}{end_htime}
      );

      if (blessed($res)) {
        for my $k (keys %HEADER) {
          $res->header($k => $HEADER{$k});
        }
      } elsif (ref($res) ne 'CODE') {
        # Danger here is we set multiple values for these headers...
        push $res->[1]->@*, %HEADER;
      }

      my @error_guids = $ctx ? $ctx->logged_exception_guids : ();

      for (@error_guids) {
        $env->{'psgi.errors'}->print("exception was reported: $_\n")
      }

      $self->log_access($req, $res, $ctx) if $self->access_log_enabled;

      if ($self->transaction_log_enabled || @error_guids) {
        $self->log_transaction($req, $res, $ctx);
      }

    } catch {
      my $error = $_;

      # Try to report the exception, if we can't, we still must return
      # a good response.
      # XXX - attach error guids to response? -- alh, 2017-04-21
      try {
        my $guid = $ctx ? $ctx->report_exception($error) : undef;
        unless ($guid) {
          warn "could not report exception: $error";
        }
      } catch {
        warn "error reporting an exception ($error)?! $_";
      };
    };

    return $res;
  };

  if ($self->processor->behind_proxy) {
    my $builder = Plack::Builder->new;
    $builder->add_middleware('ReverseProxy');
    $app = $builder->wrap($app);
  }

  return $app;
}

=method log_access($request, $response, $ctx = undef)

This simply calls C<build_access_log_entry> to generate a log entry, then
C<emit_access_log> to write it to C<access_log_fh>. This method does not,
itself, check if access logging is enabled; callers should do so themselves.

=cut

sub log_access ($self, $req, $res, $ctx = undef) {
  my $entry = $self->build_access_log_entry($req, $res, $ctx);

  $self->emit_access_log($entry);
}

=method build_access_log_entry($request, $response, $ctx = undef)

Called by C<log_access>. It pulls information out of the request and response,
(and if provided, the context object) and returns a hashref of details to log.

=cut

sub build_access_log_entry ($self, $req, $res, $ctx = undef) {
  my %entry = map {
    $_ => defined $req->$_ ? $req->$_ . "" : undef
  } qw(
    remote_host
    method
    request_uri
    content_type
    content_encoding
    content_length
    referer
    user_agent
  );

  $entry{remote_ip} = $req->address;

  my $ix_info = $req->env->{'ix.transaction'};

  $entry{$_} = $ix_info->{$_} . "" for qw(
    guid time elapsed_seconds seq
  );

  if (ref($res) && ref($res) eq 'ARRAY') {
    $entry{response_code} = $res->[0];

    $entry{response_length} = Plack::Util::content_length($res->[2]);
  }

  if ($ctx) {
    $entry{call_info} = $ctx->call_info;

    $entry{exception_guids} = [ $ctx->logged_exception_guids ]
      if $ctx->logged_exception_guids;
  }

  return \%entry;
}

=method emit_access_log($entry)

Called by C<log_access>. It takes the hashref returned by
C<build_access_log_entry>, encodes it as JSON, and writes it out
C<access_log_fh>.

=cut

sub emit_access_log ($self, $entry) {
  $self->access_log_fh->print( $self->encode_json_log($entry) . "\n" );
}

=method log_transaction($request, $response, $ctx = undef)

=method build_transaction_log_entry($request, $response, $ctx = undef)

=method emit_transaction_log($entry)

These three methods are just like the access log variants, with the exception
that the C<emit_transaction_log> stub provided here is a no-op.

=cut

sub log_transaction ($self, $req, $res, $ctx = undef) {
  my $entry = $self->build_transaction_log_entry($req, $res, $ctx);

  $self->emit_transaction_log($entry);
}

sub build_transaction_log_entry ($self, $req, $res, $ctx = undef) {
  my $entry = $self->build_access_log_entry($req, $res, $ctx);

  # Add in request/response
  $entry->{request} = $req;
  $entry->{response} = $res;

  return $entry;
}

sub emit_transaction_log ($self, $entry) {}

sub _shutdown ($self) {
  %$_ = () for $self->_caches->@*;
}

before DEMOLISHALL => sub ($self, @) {
  $self->_shutdown;
};

1;
