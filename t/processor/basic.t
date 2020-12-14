use 5.20.0;
use warnings;
use experimental qw(signatures postderef refaliasing);

use lib 't/lib';

use Bakesale;
use Capture::Tiny qw(capture_stderr);
use Test::Deep;
use Test::More;
use Safe::Isa;
use Try::Tiny;

my $no_updates = any({}, undef);

my $Bakesale = Bakesale->new;
\my %account = Bakesale::Test->load_trivial_account();
my $accountId = $account{accounts}{rjbs};

my $ctx = $Bakesale->get_context({
  userId => $account{users}{rjbs},
});

{
  my $res = $ctx->process_request([
    [ pieTypes => { tasty => 1 }, 'a' ],
    [ pieTypes => { tasty => 0 }, 'b' ],
  ]);

  is_deeply(
    $res,
    [
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan) ] }, 'a' ],
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan cherry eel) ] }, 'b' ],
    ],
    "the most basic possible call works",
  ) or diag explain($res);
}

{
  my $res = $ctx->process_request([
    [ pieTypes => { tasty => 1 } ],
    [ pieTypes => { tasty => 0 } ],
    [ pieTypes => { tasty => 1 }, 'a' ],
  ]);

  my $ci_re = re(qr/\A x [0-9]{1,4} \z/x);
  cmp_deeply(
    $res,
    [
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan) ] }, $ci_re ],
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan cherry eel) ] }, $ci_re ],
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan) ] }, 'a' ],
    ],
    "implicit client ids are added as needed",
  ) or diag explain($res);
}

{
  my $res = eval {
    $ctx->handle_calls([
      [ pieTypes => { tasty => 1 } ],
      [ pieTypes => { tasty => 0 } ],
      [ pieTypes => { tasty => 1 }, 'a' ],
    ], { no_implicit_client_ids => 1 })->as_triples;
  };

  my $error = $@;

  like(
    $error,
    qr{missing client id},
    "if unfixed, request without client ids are rejected",
  );
}

{
  my $res = $ctx->process_request([
    [ pieTypes => { tasty => 1 }, 'a' ],
    [ bakePies => { tasty => 1, pieTypes => [ qw(apple eel pecan) ] }, 'b' ],
    [ pieTypes => { tasty => 0 }, 'c' ],
  ]);

  is_deeply(
    $res,
    [
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan) ] }, 'a' ],
      [ pie   => { flavor => 'apple', bakeOrder => 1 }, 'b' ],
      [ error => { type => 'noRecipe', requestedPie => 'eel' }, 'b' ],
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan cherry eel) ] }, 'c' ],
    ],
    "a call with an error and a multi-value result",
  ) or diag explain($res);
}

my @created_ids;

subtest "results outside of request" => sub {
  eval { local $ENV{QUIET_BAKESALE} = 1; $ctx->results_so_far };

  my $error = $@;
  like(
    $error,
    qr{tried to inspect},
    "can't call ->results_so_far outside req",
  );
};

done_testing;
