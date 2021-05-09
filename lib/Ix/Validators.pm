use 5.22.0;
use warnings;
package Ix::Validators;
# ABSTRACT: validate your input

use JSON::MaybeXS ();
use Params::Util qw(_ARRAY0 _HASH0);
use Safe::Isa;
use Ix::Util qw($ix_id_re);

use experimental qw(lexical_subs postderef signatures);

use Sub::Exporter -setup => [ qw(
  array_of
  hash_of
  enum
  record
  maybe

  boolean
  integer

  string
  nonemptystr simplestr freetext
  email domain idstr state
) ];

=head1 SYNOPSIS

    use Ix::Validators qw(string email integer);

    if (my $err = string({ nonempty => 1 })->('')) {
      die "Your string is bad: $err";
    }

    if (my $err = email()->("bad.email")) {
      die "Your email is bad: $err";
    }

    my $validator = integer(-10, 10);
    if (my $err = $validator->(42)) {
      die "Your number is bad: $err";
    }

All of the validators return code references, which are called to validate
some input. Everything here is exported by L<Sub::Exporter>.

=cut

my $PRINTABLE = qr{[\pL\pN\pP\pS]};

=func string($arg)

The given value must be a string.  You can pass a hashref with some boolean
options:

=begin :list

= ascii
disallow non-ASCII characters

= nonempty
disallow empty strings

= oneline
disallow vertical whitespace

= trimmed
disallow leading and/or trailing whitespace

= printable
allow only letters, numbers, punctuation, and whitespace

=end :list

=cut

sub string ($input_arg = {}) {
  my %arg = (
    ascii     => $input_arg->{ascii    } // 0,
    nonempty  => $input_arg->{nonempty } // 0,
    oneline   => $input_arg->{oneline  } // 0,
    trimmed   => $input_arg->{trimmed  } // 0,
    printable => $input_arg->{printable} // 1,
  );

  $arg{maxlength} = $input_arg->{maxlength} // ($arg{oneline} ? 100 : 1000);

  return sub ($x, @) {
    return "not a string" unless defined $x; # weak
    return "not a string" if ref $x;

    if (0 == length $x) {
      return unless $arg{nonempty};
      return "string is empty";
    }

    return "string exceeds maximum length" if length $x > $arg{maxlength};

    if ($arg{ascii}) {
      return "string contains illegal characters" if $x =~ /\P{ASCII}/;
    }

    if ($arg{printable}) {
      return "string contains no printable characters" unless $x =~ $PRINTABLE;
    }

    if ($arg{trimmed}) {
      return "string contains leading whitespace" if $x =~ /\A\s/;
      return "string contains trailing whitespace" if $x =~ /\s\z/;
    }

    if ($arg{oneline}) {
      return "string contains vertical whitespace" if $x =~ /\v/;
    }

    return;
  };
}

=func simplestr()

An alias for C<< string({ oneline => 1 }) >>.

=func nonemptystr()

An alias for C<< string({ nonempty => 1 }) >>.

=func freetext()

An alias for C<< string() >>; may be multiline.

=cut

BEGIN {
  *simplestr   = sub { string({ oneline  => 1 }) };
  *nonemptystr = sub { string({ nonempty => 1 }) };
  *freetext    = sub { string() };
}

=func array_of($validator)

The given value must be an array of some kind of other validator. For the
validator C<< my $val = array_of(integer(-10, 10)) >>, for example,
C<[1, 2, -2]> is valid, but C<5> and C<[1, 2, -42]> are not.

=cut

sub array_of ($validator) {
  return sub ($x, @) {
    return "value is not an array" unless _ARRAY0($x);

    my @errors = grep {; defined } map {; $validator->($_) } @$x;
    return unless @errors;

    # Sort of pathetic. -- rjbs, 2017-05-10
    return "invalid values in array";
  };
}

=func hash_of($validator)

The given value must be a hash where the keys don't matter but the values
must be some kind of other validator. For the validator
C<< my $val = hash_of(integer(-10, 10)) >>, for example,
C<{ x => 1, y => 2, z => -2}> is valid, but C<5> and
C<{ x => "cat" }> are not.

=cut

sub hash_of ($validator) {
  return sub ($x, @) {
    return "value is not a hash" unless _HASH0($x);

    my @errors = grep {; defined } map {; $validator->($_) } values %$x;
    return unless @errors;

    # Sort of pathetic. -- rjbs, 2017-05-10
    return "invalid values in hash";
  };
}

=func maybe($validator)

The given value must be either undef, for validate with the given other
validator.

=cut

sub maybe ($validator) {
  return sub ($x, @) {
    return unless defined $x;
    return $validator->($x);
  };
}

=func record($arg)

The given value must be a hashref, with optional additional validation.
C<$arg> is a hashref, which can have three keys:

=begin :list

= required

Either an arrayref or hashref of keys that are required. If you provide an
arrayref, the keys must simply be present in the validated value. If you
provide a hashref, the values should be other validators.

= optional

The same kind of structure as C<required>, but these are, well, optional.

= throw

If false, errors are simply returned from the validator; if true, errors are wrapped in
L<Ix::Error::Generic> objects and thrown as exceptions.

=end :list

This is probably easiest to understand by way of an example:

    state $check = record({
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

To validate, a hashref B<must> have the C<needful> key, but the value can be
anything at all. It B<may> have a C<whatever> key, but if it does, it must be
between -1 and 1. If there's a C<subrec> key, the subrecord must have a
C<color> key which is either red, green, or blue, and may have a C<saturation>
key. If validation fails for this record, it will be thrown as an exception.

=cut

sub record ($arg) {
  # { required => [...], optional => [...], throw => bool }
  my %check
    = ! $arg->{required}        ? ()
    : _ARRAY0($arg->{required}) ? (map {; $_ => undef } $arg->{required}->@*)
    :                             $arg->{required}->%*;

  my %is_required = map {; $_ => 1 } keys %check;

  my %opt
    = ! $arg->{optional}        ? ()
    : _ARRAY0($arg->{optional}) ? (map {; $_ => undef } $arg->{optional}->@*)
    :                             $arg->{optional}->%*;

  my @duplicates  = grep {; exists $check{$_} } keys %opt;

  Carp::confess("keys listed as both optional and required: @duplicates")
    if @duplicates;

  %check = (%check, %opt);

  my %is_allowed  = map {; $_ => 1 } keys %check;
  my $throw       = $arg->{throw};

  return sub ($got) {
    my %error = map  {; $_ => "no value given for required argument" }
                grep {; ! exists $got->{$_} } keys %is_required;

    KEY: for my $key (keys %$got) {
      unless ($is_allowed{$key}) {
        $error{$key} = "unknown argument";
        next KEY;
      }

      next unless $check{$key};
      next unless my $error = $check{$key}->($got->{$key});
      $error{$key} = $error;
    }

    return unless %error;

    return \%error unless $throw;

    require Ix::Result;
    Ix::Error::Generic->new({
      error_type => 'invalidArguments',
      properties => { invalidArguments => \%error },
    })->throw;
  }
}

=func boolean

The given value must be a JSON boolean (like JSON::true or JSON::false).

=cut

sub boolean {
  return sub ($x, @) {
    return "not a valid boolean value" unless JSON::MaybeXS::is_bool($x);
    return;
  };
}

=func email

The given value must be a valid email address. This does not do full RFC-style
validation, but should be good enough for most general cases. Notably, it does
I<not> check for a valid top-level domain.

=func domain

The given value must plausibly look like a valid domain name. This does no DNS
lookups, but is useful for initial validation.

=cut

{
  my $tld_re =
    qr{
       ([-0-9a-z]+){1,63}  # top level domain
     }xi;

  my $domain_re =
    qr{
       ([a-z0-9](?:[-a-z0-9]*[a-z0-9])?\.)+   # subdomain(s), sort of
       $tld_re
     }xi;

  my sub is_domain {
    my $value = shift;
    return unless defined $value and $value =~ /\A$domain_re\z/;
    return unless length($value) <= 253;

    # We used to further check that the TLD was a valid TLD.  This made a lot
    # more sense when there was a list of, say, 50 TLDs that changed only under
    # exceptional circumstances.  I just (2016-12-16) updated the Pobox TLD
    # file from the root hosts and it added 336 new TLDs.  I think this is no
    # longer worth the effort.  We can add an email at yourface.bogus and it
    # will never be deliverable, and we'll eventually purge it because of that.
    # Fine. -- rjbs, 2016-12-16
    return 1;
  }

  my sub is_email_localpart {
    my $value = shift;

    return unless defined $value and length $value;

    my @words = split /\./, $value, -1;
    return if grep { ! length or /[\x00-\x20\x7f<>()\[\]\\.,;:@"]/ } @words;
    return 1;
  }

  my sub is_email {
    my $value = shift;

    # If we got nothing, or just blanks, it's bogus.
    return unless defined $value and $value =~ /\S/;

    return if $value =~ /\P{ASCII}/;

    # We used to strip leading and trailing whitespace, but that means that
    # is_email would return an new value, meaning that it could not accurately be
    # used as a bool.  If we need a method that does return the email address
    # eked out from a string with spaces, we should write it and then not name it
    # like a predicate.  -- rjbs, 2007-01-31

    my ($localpart, $domain) = split /@/, $value, 2;

    return unless is_email_localpart($localpart);
    return unless is_domain($domain);

    return $value;
  }

  sub email {
    return sub ($x, @) {
      return if is_email($x);
      return "not a valid email address";
    }
  }

  sub domain {
    return sub ($x, @) {
      # XXX Obviously bogus.
      return if is_domain($x);
      return "not a valid domain";
    };
  }
}

=func enum($values)

The given value must match one of the values given in the arrayref C<$values>.
For the validator C<< my $val = enum([qw(red green)]) >>, C<< $val->('red') >>
passes and C<< $val->('blue') >> fails.

=cut

sub enum ($values) {
  my %is_valid = map {; $_ => 1 } @$values;
  return sub ($x, @) {
    return "not a valid value" unless $is_valid{$x};
    return;
  };
}

=func integer($min, $max)

The given value must be an integer between C<$min> and C<$max> (inclusive).
C<$min> defaults to -Inf, and C<$max> to Inf.

=cut

sub integer ($min = '-Inf', $max = 'Inf') {
  return sub ($x, @) {
    return "not an integer" unless $x =~ /\A[-+]?(?:[0-9]|[1-9][0-9]*)\z/;
    return "value below minimum of $min" if $x < $min;
    return "value above maximum of $max" if $x > $max;
    return;
  };
}

=func state($min, $max)

The given value must be an integer between C<$min> and C<$max>, which default to
-2**31 and 2**31, respectively.

=cut

sub state ($min = -2**31, $max = 2**31-1) {
  return sub ($x, @) {
    return "not an integer" unless $x =~ /\A[-+]?(?:[0-9]|[1-9][0-9]*)\z/;
    return "value below minimum of $min" if $x < $min;
    return "value above maximum of $max" if $x > $max;
    return;
  };
}

=func idstr

The given value must be a valid id string. For now this means any GUID string
(case-insensitive), but may change in the future.

=cut

sub idstr {
  return sub ($x, @) {
    return "invalid id string" unless defined $x; # weak
    return "invalid id string" if ref $x;
    return "invalid id string" if $x !~ /\A$ix_id_re\z/;
    return;
  }
}

1;

