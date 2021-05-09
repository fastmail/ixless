use 5.20.0;
package Ix::Util;
# ABSTRACT: utility methods for all your Ix needs

use experimental qw(signatures postderef);

use DateTime::Format::Pg;
use DateTime::Format::RFC3339;
use Safe::Isa;
use Scalar::Util qw(blessed);
use Data::GUID qw(guid_string);
use Package::Stash;
use Params::Util qw(_ARRAY0 _HASH0 );
use JSON::MaybeXS qw(is_bool);

use Sub::Exporter -setup => {
  exports    => [ qw(parsedate parsepgdate differ ix_new_id splitquoted) ],
  collectors => [
    '$ix_id_re' => \'_export_ix_id_re',
  ],
};

=head1 OVERVIEW

This module exports (via L<Sub::Exporter>) a bunch of utility methods. More
interestingly, it also includes C<Ix::DateTime>.

=head2 Ix::DateTime

Ix::DateTime is a subclass of L<DateTime> that makes generating JMAP-style
(RFC 3339) dates easier. It includes a C<to_string> method and overloads
stringification (and C<TO_JSON>) so that you can just include Ix::DateTime
objects in places where you need date-time strings without thinking too hard.

=cut

sub _export_ix_id_re {
  my ($class, $value, $data) = @_;

  my $stash = Package::Stash->new($data->{into});
  # http://stackoverflow.com/questions/17146061/extract-guid-from-line-via-regular-expression-in-perl
  # For now, this is just a straight up guid
  $stash->add_symbol(
    '$ix_id_re',
    \qr/([a-f\d]{8}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{4}-([a-f\d]){12})/an,
  );

  return 1;
}

my $pg = DateTime::Format::Pg->new();
my $rfc3339 = DateTime::Format::RFC3339->new();

=func ix_new_id

Return a new string (a guid) suitable for use as an ID.

=cut

sub ix_new_id { lc guid_string() }

=func parsepgdate($str)

Given a datetime string from Postgres, returns an C<Ix::DateTime> object. This
is parsed with C<DateTime::Format::Pg>.

=cut

sub parsepgdate ($str) {
  my $dt;
  return unless eval { $dt = $pg->parse_datetime($str) };

  bless $dt, 'Ix::DateTime';
}

=func parsepgdate($str)

Given a JMAP date (like "2017-09-12T12:34:56Z"), returns an C<Ix::DateTime>
object. This is parsed with L<DateTime::Format::RFC3339>, but the time must be
in Zulu time with no fractional seconds.

=cut

sub parsedate ($str) {
  return unless $str =~ /Z\z/; # must be in zulu time
  return if $str =~ /\./; # no fractional seconds

  my $dt;
  return unless eval { $dt = $rfc3339->parse_datetime($str) };

  bless $dt, 'Ix::DateTime';
}

=func differ($x, $y)

This returns true if two scalars differ as potential Ix property values.
This means:

=for :list

* definedness differs
* not the same datetime
* not the same is-ref (except for date; you can compare date obj + str)
* string inequality for non-refs
* boolean inequality for bools
* not equivalent arrays
* otherwise, throw exception

=cut

sub differ ($x, $y) {
  return 1 if defined $x xor defined $y;
  return unless defined $x;

  if ($x->$_isa('Ix::DateTime') || $y->$_isa('Ix::DateTime')) {
    return $x ne $y;
  }

  return 1 if ref $x xor ref $y;
  return $x ne $y if ! ref $x;

  return ($x xor $y) if is_bool($x) && is_bool($y);

  if (blessed $x || blessed $y) {
    Carp::croak("can't compare non-Boolean, non-DateTime objects with differ");
  }

  if (_ARRAY0($x) && _ARRAY0($y)) {
    return 1 if @$x != @$y;
    for (0 .. $#$x) {
      return 1 if differ($x->[$_], $y->[$_]);
    }
    return;
  }

  Carp::croak "can't compare two references with differ";
}

=func splitquoted($str)

Given a string, this splits into quoted sections, then returns the list.
Some examples:

    splitquoted(q{foo});                     # ('foo')
    splitquoted(q{foo bar});                 # ('foo', 'bar')
    splitquoted(q{"foo bar" baz});           # ('foo bar', 'baz')
    splitquoted(q{"foo bar" 'baz quux'});    # ('foo bar', 'baz quux')
    splitquoted(q{"foo \"bar\"" thud'});     # ('foo "bar"', 'thud')

=cut

sub splitquoted ($str) {
  my @found;

  while ($str =~ /\S/) {
    $str =~ s/\A\s+//;

    my ($quote) = $str =~ /\A(["'])/;
    if ($quote && $str =~ s/\A$quote((?:[^$quote\\]++|\\.)*+)$quote//) {
      my $extract = $1;
      $extract =~ s/\\(.)/$1/g;
      push @found, $extract;
    } else {
      $str =~ s/\A(\S+)\s*//;
      push @found, $1;
    }
  }

  return @found;
}

=func resolve_modified_jpointer($pointer, $value)

Resolve a JSON Pointer (C<$pointer>) as modified by the JMAP spec (RFC 8620).
This is just like JSON Pointer (RFC 6901), except it also allows the use of
C<*> to map through an array. C<$value> is a reference to search.

    my ($result, $error) = resolve_modified_jpointer('/foo', { foo => 'bar' });
    # $result is 'bar', $error is undef

    my ($result, $error) = resolve_modified_jpointer('/foo', []);
    # $result is undef, $error has some descriptive string

=cut

# my ($result, $error) = resolve_modified_jpointer($p, $v);
#   only one of $result or $error will be defined
sub resolve_modified_jpointer ($pointer, $value) {
  return (undef, "no pointer given") unless defined $pointer;
  return (undef, "pointer begins with non-slash") if $pointer =~ m{\A[^/]};

  # Drop the leading empty bit.  Don't drop trailing empty bits.
  my (undef, @tokens) = split m{/}, $pointer, -1;

  s{~1}{/}g, s{~0}{~}g for @tokens;

  my ($result, $error) = _descend_modified_jpointer(\@tokens, $value);

  return $result unless wantarray;

  if (ref $error) {
    my ($e, @i) = @$error;
    $error = sprintf "%s with %s indexing %s",
      $e,
      (@i > 1 ? "asterisks" : "asterisk"),
      join q{,}, reverse @i;
  }

  return ($result, $error);
}

sub _descend_modified_jpointer {
  my ($token_queue, $value, $pos) = @_;
  $pos //= '';

  my $error;

  TOKEN: while (defined(my $token = shift @$token_queue)) {
    $pos .= "/$token";

    if (_ARRAY0($value)) {
      if ($token eq '*') {
        my @map;
        for my $i (0 .. $#$value) {
          my ($i_result, $i_error) = _descend_modified_jpointer(
            [@$token_queue],
            $value->[$i],
            $pos,
          );

          if ($i_error) {
            $error = [ (ref $i_error ? @$i_error : $i_error), $i ];
            last TOKEN;
          }

          push @map, _ARRAY0($i_result) ? @$i_result : $i_result;
        }

        $value = \@map;
        last TOKEN;
      }

      if ($token eq '-') {
        # Special notice that this will never work in JMAP, even though it's
        # valid JSON Pointer. -- rjbs, 2018-01-10
        $error = qq{"-" not allowed as array index in JMAP at $pos};
        last TOKEN;
      }

      if ($token eq '0' or $token =~ /\A[1-9][0-9]*\z/) {
        if ($token > $#$value) {
          $error = qq{index out of bounds at $pos};
          last TOKEN;
        }

        $value = $value->[$token];
        next TOKEN;
      }
    }

    if (_HASH0($value)) {
      unless (exists $value->{$token}) {
        $error = qq{property does not exist at $pos};
        last TOKEN;
      }

      $value = $value->{$token};
      next TOKEN;
    }

    $error = qq{can't descend into non-Array, non-Object at $pos};
    last TOKEN;
  }

  return (undef, $error) if $error;
  return ($value, undef);
}

1;

package Ix::DateTime {

  use parent 'DateTime'; # should use DateTime::Moonpig

  use overload '""' => 'as_string';

  sub as_string ($self, @) {
    $rfc3339->format_datetime($self->clone->truncate(to => 'second'));
  }

  sub TO_JSON ($self) {
    $rfc3339->format_datetime($self->clone->truncate(to => 'second'));
  }
}

1;
