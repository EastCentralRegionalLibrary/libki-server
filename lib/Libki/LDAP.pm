package Libki::LDAP;

=head2 authenticate_via_ldap

Authenticates a given username and password via LDAP.

=cut

sub authenticate_via_ldap {
    my ( $c, $user, $username, $password ) = @_;

    my $instance = $c->instance;
    my $config = $c->config->{instances}->{$instance} || $c->config;

    my $log = $c->log();

    my $adminDn           = $config->{LDAP}->{adminDn};
    my $adminPwd          = $config->{LDAP}->{adminPwd};
    my $searchBase        = $config->{LDAP}->{searchBase};
    my $host              = $config->{LDAP}->{host};
    my $port              = $config->{LDAP}->{port};
    my $ldaps             = $config->{LDAP}->{ldaps};
    my $match_attribute   = $config->{LDAP}->{match_attribute};
    my $require_ldap_auth = $config->{LDAP}->{require_ldap_auth}
      // 1;    # Default to requiring authentication if setting doesn't exist

    # TLS options: verify = none (default, as before) | optional | require
    my $ldap_opts = {
        verify => $config->{LDAP}->{verify},
        cafile => $config->{LDAP}->{cafile},
        capath => $config->{LDAP}->{capath},
    };

    my $data;
    my $patron_status_request;


    if ($require_ldap_auth) {

	my $userdn = testGuid( $username, $password, $adminDn, $adminPwd, $searchBase, $host, $port, $ldaps, $match_attribute, $ldap_opts );

        if ( $userdn ) {
    		#$log->debug("userdn: $userdn");
        }
        else {
            return { success => 0, error => 'LDAP_AUTH_FAILURE', user => $user };
        }
    }

    if ($user) {    ## User authenticated and exists in Libki
        $user->set_column( 'password', $password );
        $user->update();
    }
    else {          ## User authenticated and does not exist in Libki
        $user = $c->model('DB::User')->create(
            {
                instance          => $instance,
                username          => $username,
                password          => $password,
                status            => 'enabled',
                creation_source   => 'LDAP',
            }
        );
    }

    if ( my $deny_on = $config->{LDAP}->{deny_on} ) {
        my @deny_on = ref($deny_on) eq "ARRAY" ? @$deny_on : $deny_on;

        foreach my $d (@deny_on) {
            if ( $sip_fields->{patron_status}->{$d} eq 'Y' ) {
                return { success => 0, error => uc($d), user => $user };
            }
        }
    }

    return { success => 1, user => $user };

}

=head2 _new_ldap

Opens the LDAP(S) connection. C<$port> is used when C<$host> is a plain host
name (a port in an C<ldap://> URL wins). C<$opts> may hold C<verify>
(none, optional or require; default none), C<cafile> and C<capath>.

=cut

sub _new_ldap {
    my ( $host, $port, $ldaps, $opts ) = @_;
    $opts ||= {};

    my $verify = $opts->{verify} || 'none';
    die "Invalid LDAP verify setting '$verify' (use none, optional or require)"
      unless $verify =~ /^(?:none|optional|require)$/;

    my %args = ( verify => $verify );
    $args{port}   = $port           if $port;
    $args{cafile} = $opts->{cafile} if $opts->{cafile};
    $args{capath} = $opts->{capath} if $opts->{capath};

    my $class = $ldaps ? 'Net::LDAPS' : 'Net::LDAP';
    ( my $file = "$class.pm" ) =~ s{::}{/}g;
    require $file;

    return $class->new( $host, %args ) || die "$@";
}

=head2 getUserDn

=cut

sub getUserDn {
    my $ldap;
    my $guid = shift;
    my $dn;
    my $entry;

    my $adminDn = shift;
    my $adminPwd = shift;
    my $searchBase = shift;
    my $host = shift;
    my $port = shift;
    my $ldaps = shift;
    my $match_attribute = shift;
    my $ldap_opts = shift;

    my $filter = $match_attribute . '=' . $guid;

    $ldap = _new_ldap( $host, $port, $ldaps, $ldap_opts );
    
    my $mesg = $ldap->bind ($adminDn, password=>"$adminPwd");
    
    $mesg->code && return undef;
    
    $mesg = $ldap->search(base => $searchBase, filter => "$filter" ) ; 
    #$mesg = $ldap->search(base => $searchBase, filter => "sAMAccountName=$guid" ) ; 
    $mesg->code && return undef;
    $entry = $mesg->shift_entry;
     
    if ($entry) {
        $dn = $entry->dn;
        #$entry->dump;
    }
    
    $ldap->unbind;
    
    return $dn;
}

=head2 testGuid

=cut

sub testGuid {
    my $ldap;

    my $guid = shift;
    my $userPwd = shift;

    my $adminDn = shift;
    my $adminPwd = shift;
    my $searchBase = shift;
    my $host = shift;
    my $port = shift;
    my $ldaps = shift;
    my $match_attribute = shift;
    my $ldap_opts = shift;

    $ldap = _new_ldap( $host, $port, $ldaps, $ldap_opts );

    my $userDn = getUserDn($guid, $adminDn, $adminPwd, $searchBase, $host, $port, $ldaps, $match_attribute, $ldap_opts );

    return undef unless $userDn;
    
    my $mesg = $ldap->bind ($userDn, password=>"$userPwd");
    
    if ($mesg->code) {
        # Bad Bind
        print $mesg->error . "\n";
        return undef;
    }
    
    $ldap->unbind;
    
    return $userDn;
}


1;
