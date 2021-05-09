use 5.20.0;
use warnings;
use experimental qw(lexical_subs signatures postderef);

package Bakesale::Test {
  use File::Temp qw(tempdir);
  use Ix::Util qw(ix_new_id);

  sub new_test_app_and_tester ($self) {
    require JMAP::Tester;
    require LWP::Protocol::PSGI;

    my $app = Bakesale::App->new({
      transaction_log_enabled => 1,
    });

    state $n;
    $n++;
    LWP::Protocol::PSGI->register($app->to_app, host => 'bakesale.local:' . $n);
    my $jmap_tester = JMAP::Tester->new({
      api_uri => "http://bakesale.local:$n/jmap",
    });

    return ($app, $jmap_tester);
  }

  sub load_trivial_account ($self) {
    return {};
  }

}

package Bakesale {
  use Moose;
  with 'Ix::Processor::JMAP';

  use HTTP::Throwable::JSONFactory qw(http_throw);

  use Bakesale::Context;
  use Data::GUID qw(guid_string);
  use Ix::Validators qw( enum integer record );

  use experimental qw(signatures postderef);
  use namespace::autoclean;

  sub exceptions;
  has exceptions => (
    lazy => 1,
    traits => [ 'Array' ],
    handles => {
      'exceptions'       => 'elements',
      'clear_exceptions' => 'clear',
      'add_exception'    => 'push',
     },
    default => sub { [] },
  );

  sub file_exception_report ($self, $ctx, $exception) {
    Carp::cluck( "EXCEPTION!! $exception" ) unless $ENV{QUIET_BAKESALE};
    $self->add_exception($exception);
    return guid_string();
  }

  sub database_defaults {
    return (
      "SET LOCK_TIMEOUT TO '2s'",
    );
  }

  sub get_context ($self, $arg) {
    Bakesale::Context->new({
      userId    => $arg->{userId},
      processor => $self,
    });
  }

  sub get_system_context ($self, $arg = {}) {
    Bakesale::Context::System->new({
      processor => $self,
    });
  }

  sub context_from_plack_request ($self, $req, $arg = {}) {
    if (my $user_id = $req->cookies->{bakesaleUserId}) {
      $user_id =~ s/"(.*)"/$1/;

      if ($ENV{BAD_ID} && $user_id eq $ENV{BAD_ID}) {
        http_throw(Gone => {
          payload => { error => "bad auth" },
        });
      }

      return $self->get_context({
        userId => $user_id,
      });
    }

    http_throw('Gone');
  }

  sub handler_for ($self, $method) {
    return 'result_count'  if $method eq 'countResults';
    return 'count_chars'   if $method eq 'countChars';
    return 'pie_type_list' if $method eq 'pieTypes';
    return 'bake_pies'     if $method eq 'bakePies';
    return 'validate_args' if $method eq 'validateArguments';
    return 'echo'          if $method eq 'echo';
    return;
  }

  sub result_count ($self, $ctx, $arg) {
    my $sc = $ctx->results_so_far;

    my $s_count = $sc->sentences;
    my $p_count = $sc->paragraphs;

    return Ix::Result::Generic->new({
      result_type       => 'resultCount',
      result_arguments  => { sentences => $s_count, paragraphs => $p_count },
    });
  }

  sub count_chars ($self, $ctx, $arg) {
    my $string = $arg->{string};
    my $length = length $string;
    return Ix::Result::Generic->new({
      result_type       => 'charCount',
      result_arguments => {
        string => $string,
        length => $length,
      },
    });
  }

  sub pie_type_list ($self, $ctx, $arg = {}) {
    my $only_tasty = delete local $arg->{tasty};
    return $ctx->error('invalidArguments') if keys %$arg;

    my @flavors = qw(pumpkin apple pecan);
    push @flavors, qw(cherry eel) unless $only_tasty;

    return Bakesale::PieTypes->new({ flavors => \@flavors });
  }

  sub validate_args ($self, $ctx, $arg = {}) {
    state $argchk = record({
      required => [ qw(needful)  ],
      optional => {
        whatever => integer(-1, 1),
        subrec   => record({
          required => { color => enum([ qw(red green blue) ]) },
          optional => [ 'saturation' ],
        }),
      },
      throw    => 1,
    });

    $argchk->($arg);

    return Ix::Result::Generic->new({
      result_type       => 'argumentsValidated',
      result_arguments  => {},
    });
  }

  sub echo ($self, $ctx, $arg) {
    return Ix::Result::Generic->new({
      result_type       => 'echoEcho',
      result_arguments  => { args => $arg->{echo} },
    });
  }

  sub bake_pies ($self, $ctx, $arg = {}) {
    return $ctx->error("invalidArguments")
      unless $arg->{pieTypes} && $arg->{pieTypes}->@*;

    my %is_flavor = map {; $_ => 1 }
                    $self->pie_type_list($ctx, { tasty => $arg->{tasty} })->flavors;

    my @rv;
    for my $type ($arg->{pieTypes}->@*) {
      if ($is_flavor{$type}) {
        push @rv, Bakesale::Pie->new({ flavor => $type });
      } else {
        push @rv, $ctx->error(noRecipe => { requestedPie => $type })
      }
    }

    return @rv;
  }

  sub optimize_calls ($self, $ctx, $calls) {
    my (@final, @combined);

    for my $c (@$calls) {
      my $is_cupcake;

      if (
           $c->[0] eq 'Cake/set'
        && keys $c->[1]->%* == 1
        && $c->[1]->{create}
        && values $c->[1]->{create}->%* == 1
      ) {
        my ($what) = values $c->[1]->{create}->%*;
        if ($what->{type} eq 'cupcake') {
          $is_cupcake = 1;
        }
      }

      if ($is_cupcake) {
        push @combined, $c;
      } else {
        if (@combined > 1) {
          push @final, Bakesale::Cupcake::Combiner->new({
            calls => [ @combined ],
          });

          @combined = ();
        } elsif (@combined) {
          push @final, @combined, $c;
        } else {
          push @final, $c;
        }
      }
    }

    if (@combined > 1) {
      push @final, Bakesale::Cupcake::Combiner->new({
        calls => [ @combined ],
      });

    } elsif (@combined) {
      push @final, @combined;
    }

    @$calls = @final;
  }

  __PACKAGE__->meta->make_immutable;
  1;
}

package Bakesale::PieTypes {
  use Moose;
  with 'Ix::Result';

  use experimental qw(signatures postderef);
  use namespace::autoclean;

  has flavors => (
    traits   => [ 'Array' ],
    handles  => { flavors => 'elements' },
    required => 1,
  );

  sub result_type { 'pieTypes' }

  sub result_arguments ($self) {
    return {
      flavors => [ $self->flavors ],
    };
  }

  __PACKAGE__->meta->make_immutable;
  1;
}

package Bakesale::Pie {
  use Moose;

  with 'Ix::Result';

  use experimental qw(signatures postderef);
  use namespace::autoclean;

  has flavor     => (is => 'ro', required => 1);
  has bake_order => (is => 'ro', default => sub { state $i; ++$i });

  sub result_type { 'pie' }
  sub result_arguments ($self) {
    return { flavor => $self->flavor, bakeOrder => $self->bake_order };
  }
}

package Bakesale::Cupcake::Combiner {
  use Moose;
  use experimental qw(lexical_subs signatures postderef);
  with 'Ix::Multicall';

  sub call_ident { 'Cake/multiset' }

  has calls => (
    is => 'ro',
    isa => 'ArrayRef',
    required => 1,
  );

  sub execute ($self, $ctx) {
    return [ [
      Ix::Result::Generic->new({
        result_type => 'Cake/set',
        result_arguments => {
          batchSize => 0+$self->calls->@*,
        },
      }), "junk",
    ] ];
  }
}

1;
