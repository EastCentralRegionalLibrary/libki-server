use Modern::Perl;
use Test::More;

use_ok('Catalyst::Plugin::LibkiSetting');

# get_rule only needs get_rules from $c, so use a stub
{
    package StubC;
    our $RULES;
    sub get_rules { $RULES }
    sub get_rule  { Catalyst::Plugin::LibkiSetting::get_rule(@_) }
}
my $c = bless {}, 'StubC';

sub rule {
    my ( $rules, %p ) = @_;
    $StubC::RULES = $rules;
    return $c->get_rule( { rule => 'session', %p } );
}

my $by_location = [
    { criteria => { client_location => 'A' }, rules => { session => 15 } },
    { rules => { session => 10 } },
];
is( rule( $by_location, client_location => 'A' ),     15, 'location matches' );
is( rule( $by_location, client_location => 'B' ),     10, 'other location falls through' );
is( rule( $by_location ),                              10, 'no location supplied does not match a location rule' );
is( rule( $by_location, client_location => '' ),      10, 'empty location does not match a location rule' );

my $multi = [
    { criteria => { user_category => [ 'Cat1', 'Cat2' ], client_location => ['A'] }, rules => { session => 25 } },
    { rules => { session => 5 } },
];
is( rule( $multi, user_category => 'Cat2', client_location => 'A' ), 25, 'list values are ORed, criteria ANDed' );
is( rule( $multi, user_category => 'Cat3', client_location => 'A' ), 5,  'category not in list' );
is( rule( $multi, client_location => 'A' ),                          5,  'list criterion with no value supplied does not match' );

my $zero = [
    { criteria => { client_location => 'A' }, rules => { daily => 0 } },
    { rules => { daily => 60 } },
];
$StubC::RULES = $zero;
is( $c->get_rule( { rule => 'daily', client_location => 'A' } ), 0,  'a value of 0 is a real value' );
is( $c->get_rule( { rule => 'daily', client_location => 'B' } ), 60, '0 rule does not leak to other locations' );

my $skip = [
    { criteria => { client_location => 'A' }, rules => { session => 15 } },
    { rules => { session => 10, guest_session => 20 } },
];
$StubC::RULES = $skip;
is( $c->get_rule( { rule => 'guest_session', client_location => 'A' } ), 20, 'rule lacking the requested value is skipped' );
is( $c->get_rule( { rule => 'nonesuch',      client_location => 'A' } ), undef, 'no rule defines it: undef' );

$StubC::RULES = undef;
is( $c->get_rule( { rule => 'session' } ), undef, 'no rules at all: undef' );

done_testing;
