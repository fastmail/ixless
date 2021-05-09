use 5.20.0;
use warnings;
use utf8;
use experimental qw(lexical_subs signatures postderef refaliasing);

use lib 't/lib';

use Bakesale;
use Bakesale::App;
use Capture::Tiny qw(capture_stderr);
use JSON::MaybeXS;
use Test::Deep;
use Test::Deep::JType;
use Test::More;
use Unicode::Normalize;
use Ix::Util qw(ix_new_id);

sub mkref ($result_of, $name, $path) {
  return { resultOf => $result_of, name => $name, path => $path }
}

my $no_updates = any({}, undef);

my ($app, $jmap_tester) = Bakesale::Test->new_test_app_and_tester;
\my %account = Bakesale::Test->load_trivial_account;

my $accountId = $account{accounts}{rjbs};

$jmap_tester->_set_cookie('bakesaleUserId', 42);

{
  $app->clear_transaction_log;

  my $res = $jmap_tester->request([
    [ pieTypes => { tasty => 1 } ],
    [ pieTypes => { tasty => 0 } ],
  ]);

  jcmp_deeply(
    $res->sentence(0)->as_pair,
    [ pieTypes => { flavors => [ qw(pumpkin apple pecan) ] } ],
    "first call response: as expected",
  );

  jcmp_deeply(
    $res->paragraph(1)->single->as_pair,
    [ pieTypes => { flavors => [ qw(pumpkin apple pecan cherry eel) ] } ],
    "second call response group: one item, as expected",
  );

  my @xacts = $app->drain_transaction_log;
  is(@xacts, 1, "we log transactions (at least when testing)");
}

{
  my $res = $jmap_tester->request([
    [ pieTypes => { tasty => 1 } ],
    [ bakePies => { tasty => 1, pieTypes => [ qw(apple eel pecan) ] } ],
    [ pieTypes => { tasty => 0 } ],
  ]);

  my ($pie1, $bake, $pie2) = $res->assert_n_paragraphs(3);

  cmp_deeply(
    $pie1->as_stripped_pairs,
    [
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan) ] } ],
    ],
    "pieTypes call 1 reply: as expected",
  );

  jcmp_deeply(
    $bake->as_pairs,
    [
      [ pie   => { flavor => 'apple', bakeOrder => jnum(1) } ],
      [ error => { type => 'noRecipe', requestedPie => jstr('eel') } ],
    ],
    "bakePies call reply: as expected",
  );

  cmp_deeply(
    $jmap_tester->strip_json_types( $pie2->as_pairs ),
    [
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan cherry eel) ] } ],
    ],
    "pieTypes call 2 reply: as expected",
  );
}

my @created_ids;

subtest "non-ASCII data" => sub {
  subtest "HTTP, no database layer" => sub {
    for my $test (
      [ rjbs      => 4 ],
      [ 'Grüß'    => 4 ],
      [ '芋头糕'  => 3 ],
      # TODO: normalize, test for normalization
    ) {
      my $res = $jmap_tester->request([
        [ countChars => { string => $test->[0] } ],
      ]);

      my $got = $res->single_sentence('charCount')->as_stripped_pair->[1];

      my $data = JSON->new->utf8->decode($res->http_response->decoded_content);
      $data = $data->{methodResponses} if ref $data eq 'HASH';

      is(
        $data->[0][1]->{string},
        $test->[0],
        "string round tripped (HTTP)",
      );

      is($got->{string}, $test->[0], "string round tripped (JMAP::Tester)");
      is($got->{length}, $test->[1], "correct length");
    }
  };
};

subtest "additional request handling" => sub {
  $app->clear_transaction_log;

  my $uri = $jmap_tester->api_uri;
  $uri =~ s/jmap$/secret/;
  my $res = $jmap_tester->ua->get($uri);
  is(
    $res->content,
    "Your secret is safe with me.\n",
    "we can hijack request handling",
  );

  my @xacts = $app->drain_transaction_log;
  is(@xacts, 1, "we log the /secret transaction");

  is(
    join(q{}, $xacts[0]{response}[2]->@*),
    "Your secret is safe with me.\n",
    "...and it has the response body, for example",
  );
};

subtest "good call gets headers" => sub {
  $jmap_tester->ua->default_header('Origin' => 'example.net');

  my $res = $jmap_tester->request([
    [ 'countChars' => { string => 'hello I am a string' } ],
  ]);

  ok($res->sentence(0)->arguments->{length}, 'got a good response');

  my $http_res = $res->http_response;

  is($http_res->header('Vary'), 'Origin', 'Vary is correct');

  ok($http_res->header('Ix-Transaction-ID'), 'we have a request guid!');
};

subtest "argument validation" => sub {
  my sub validate ($args) {
    $jmap_tester->request([[ validateArguments => $args ]])
                ->single_sentence
                ->as_pair;
  }

  jcmp_deeply(
    validate({ needful => 1 }),
    [ argumentsValidated => { } ],
    "first call response: okay",
  ) or diag explain(
    validate({ needful => 1 }),
  );

  jcmp_deeply(
    validate({ needful => 1, whatever => 1 }),
    [ argumentsValidated => { } ],
    "second call response: okay",
  );

  jcmp_deeply(
    validate({ bogus => 1 }),
    [
      error => {
        type => 'invalidArguments',
        invalidArguments => {
          bogus   => "unknown argument",
          needful => "no value given for required argument",
        },
      },
    ],
    "third call response: expected errors",
  );

  jcmp_deeply(
    validate({ bogus => 1, needful => 1 }),
    [
      error => {
        type => 'invalidArguments',
        invalidArguments => {
          bogus   => "unknown argument",
        },
      },
    ],
    "fourth call response: expected errors",
  );

  jcmp_deeply(
    validate({ needful => 1, whatever => 10 }),
    [
      error => {
        type => 'invalidArguments',
        invalidArguments => {
          whatever  => "value above maximum of 1",
        },
      },
    ],
    "fourth call response: expected errors",
  );

  jcmp_deeply(
    validate({ needful => 1, subrec => { color => 'orange' } }),
    [
      error => {
        type => 'invalidArguments',
        invalidArguments => {
          subrec => {
            color => "not a valid value"
          }
        },
      }
    ],
    "invalid subrecord: bad enum value",
  );

  jcmp_deeply(
    validate({ needful => 1, subrec => { awful => 1 } }),
    [
      error => {
        type => 'invalidArguments',
        invalidArguments => {
          subrec => {
            color => "no value given for required argument",
            awful => "unknown argument",
          }
        },
      }
    ],
    "invalid subrecord: missing and unknown",
  );

  jcmp_deeply(
    validate({ needful => 1, subrec => { color => 'red' } }),
    [ argumentsValidated => { } ],
    "valid subrecord",
  );
};

{
  my $res = $jmap_tester->request([
    [ countResults => { }, 'a' ],
    [ bakePies => { tasty => 1, pieTypes => [ qw(apple eel pecan) ] }, 'b' ],
    [ countResults => { }, 'c' ],
    [ countResults => { }, 'c' ],
    [ countResults => { }, 'c' ],
  ]);

  my ($p1, $p2, $p3) = $res->assert_n_paragraphs(3);

  jcmp_deeply(
    $p1->as_triples,
    [
      [ resultCount => { sentences => 0, paragraphs => 0 }, 'a' ],
    ],
    "countResults before anything is done",
  );

  jcmp_deeply(
    $p2->as_triples,
    [
      [ pie   => { flavor => 'apple', bakeOrder => jnum() }, 'b' ],
      [ error => { type => 'noRecipe', requestedPie => jstr('eel') }, 'b' ],
    ],
    "bakePies call reply: as expected",
  );

  jcmp_deeply(
    $p3->as_triples,
    [
      [ resultCount => { sentences => 3, paragraphs => 2 }, 'c' ],
      [ resultCount => { sentences => 4, paragraphs => 3 }, 'c' ],
      [ resultCount => { sentences => 5, paragraphs => 3 }, 'c' ],
    ],
    "resultCount called 3x with one cid",
  );
}

subtest "result references" => sub {
  my sub ref_error ($desc = undef, $cid = undef) {
    return [
      error => superhashof({
        type => 'resultReference',
        ($desc ? (description => $desc) : ()),
      }),
      $cid // ignore(),
    ]
  }

  my $res = $jmap_tester->request([
    [ echo => {   echo  => [ 1, 2, 3 ] }, 'a' ],
    [ echo => { '#echo' => [ 1, 2, 3 ] }, 'b' ],
    [ echo => { '#echo' => mkref(qw( a echoEcho /args/1 )) }, 'c' ],
    [ echo => { echo => 1, '#E' => mkref(qw(a echoEcho /args/1)) }, 'd' ],
    [ echo => { echo => 1, '#echo' => mkref(qw(a echoEcho /args/1)) }, 'e' ],
    [ echo => { '#echo' => mkref(qw(f echoEcho /args/1)) }, 'f' ],
    [ echo => { '#echo' => mkref(qw(a echoEcho /args/8/1)) }, 'g' ],
    [ echo => { '#echo' => mkref(qw( a reverb /args/1 )) }, 'h' ],
    [ echo => {   echo  => [ {a=>10}, {a=>[20 .. 29]}, {a=>30} ] }, 'i' ],
    [ echo => { '#echo' => mkref(qw(i echoEcho /args/*/a)) }, 'j' ],
  ]);

  jcmp_deeply(
    $res->as_triples,
    [
      [ echoEcho => { args => [ 1, 2, 3 ] }, 'a' ],
      ref_error('malformed ResultReference', 'b'),
      [ echoEcho => { args => 2           }, 'c' ],
      [ echoEcho => { args => 1           }, 'd' ],
      ref_error('arguments present as both ResultReference and not: echo', 'e'),
      ref_error('no result for client id f', 'f'),
      ref_error('error with path: index out of bounds at /args/8', 'g'),
      ref_error('first result for client id a is not reverb but echoEcho', 'h'),
      [ echoEcho => { args => [ {a=>10}, {a=>[20 .. 29]}, {a=>30} ] }, 'i' ],
      [ echoEcho => { args => [ 10, 20 .. 29, 30 ] }, 'j' ],
    ],
    "simple echo response",
  ) or diag explain($res->as_stripped_triples);
};

subtest "exeptions are not thrown twice" => sub {
  my $uri = $jmap_tester->api_uri;
  $uri =~ s/jmap$/exception/;

  local $ENV{QUIET_BAKESALE} = 1;

  $app->processor->clear_exceptions;

  my (undef, $res) = capture_stderr(sub { $jmap_tester->ua->get($uri) });
  like(
    $res->content,
    qr/"error":"internal"/,
    "got an exception",
  );

  is($app->processor->exceptions, 1, 'got 1 exception');
  is(($app->processor->exceptions)[0]->ident, 'I except!', 'expected');
};

subtest "multicalls" => sub {
  my $res = $jmap_tester->request([
    [
      'Cake/set' => {
        create => {
          1 => { type => 'cupcake', recipeId => $account{recipes}{1}, layer_count => 1, },
        },
      }
    ],
    [
      'Cake/set' => {
        create => {
          2 => { type => 'cupcake', recipeId => $account{recipes}{1}, layer_count => 1, },
        },
      }
    ],
    [
      'Cake/set' => {
        create => {
          3 => { type => 'cupcake', recipeId => $account{recipes}{1}, layer_count => 1, },
        },
      }
    ],
  ]);

  jcmp_deeply(
    $res->sentence_named('Cake/set')->arguments,
    { batchSize => 3, },
    'got a single batch of cupcakes'
  );
};

$app->_shutdown;

done_testing;
