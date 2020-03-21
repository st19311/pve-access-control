package PVE::Auth::Plugin;

use strict;
use warnings;
use Encode;
use Digest::SHA;
use PVE::Tools;
use PVE::SectionConfig;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_lock_file);

use base qw(PVE::SectionConfig);

my $domainconfigfile = "domains.cfg";

cfs_register_file($domainconfigfile,
		  sub { __PACKAGE__->parse_config(@_); },
		  sub { __PACKAGE__->write_config(@_); });

sub lock_domain_config {
    my ($code, $errmsg) = @_;

    cfs_lock_file($domainconfigfile, undef, $code);
    my $err = $@;
    if ($err) {
	$errmsg ? die "$errmsg: $err" : die $err;
    }
}

our $realm_regex = qr/[A-Za-z][A-Za-z0-9\.\-_]+/;
our $user_regex = qr![^\s:/]+!;

PVE::JSONSchema::register_format('pve-realm', \&pve_verify_realm);
sub pve_verify_realm {
    my ($realm, $noerr) = @_;

    if ($realm !~ m/^${realm_regex}$/) {
	return undef if $noerr;
	die "value does not look like a valid realm\n";
    }
    return $realm;
}

PVE::JSONSchema::register_standard_option('realm', {
    description => "Authentication domain ID",
    type => 'string', format => 'pve-realm',
    maxLength => 32,
});

my $realm_sync_options_desc = {
    scope => {
	description => "Select what to sync.",
	type => 'string',
	enum => [qw(users groups both)],
	optional => '1',
    },
    full => {
	description => "If set, uses the LDAP Directory as source of truth,"
	    ." deleting users or groups not returned from the sync. Otherwise"
	    ." only syncs information which is not already present, and does not"
	    ." deletes or modifies anything else.",
	type => 'boolean',
	optional => '1',
    },
    'enable-new' => {
	description => "Enable newly synced users immediately.",
	type => 'boolean',
	default => '1',
	optional => '1',
    },
    purge => {
	description => "Remove ACLs for users or groups which were removed from"
	    ." the config during a sync.",
	type => 'boolean',
	optional => '1',
    },
};
PVE::JSONSchema::register_standard_option('realm-sync-options', $realm_sync_options_desc);
PVE::JSONSchema::register_format('realm-sync-options', $realm_sync_options_desc);

PVE::JSONSchema::register_format('pve-userid', \&verify_username);
sub verify_username {
    my ($username, $noerr) = @_;

    $username = '' if !$username;
    my $len = length($username);
    if ($len < 3) {
	die "user name '$username' is too short\n" if !$noerr;
	return undef;
    }
    if ($len > 64) {
	die "user name '$username' is too long ($len > 64)\n" if !$noerr;
	return undef;
    }

    # we only allow a limited set of characters
    # colon is not allowed, because we store usernames in
    # colon separated lists)!
    # slash is not allowed because it is used as pve API delimiter
    # also see "man useradd"
    if ($username =~ m!^(${user_regex})\@(${realm_regex})$!) {
	return wantarray ? ($username, $1, $2) : $username;
    }

    die "value '$username' does not look like a valid user name\n" if !$noerr;

    return undef;
}

PVE::JSONSchema::register_standard_option('userid', {
    description => "User ID",
    type => 'string', format => 'pve-userid',
    maxLength => 64,
});

my $tfa_format = {
    type => {
        description => "The type of 2nd factor authentication.",
        format_description => 'TFATYPE',
        type => 'string',
        enum => [qw(yubico oath)],
    },
    id => {
        description => "Yubico API ID.",
        format_description => 'ID',
        type => 'string',
        optional => 1,
    },
    key => {
        description => "Yubico API Key.",
        format_description => 'KEY',
        type => 'string',
        optional => 1,
    },
    url => {
        description => "Yubico API URL.",
        format_description => 'URL',
        type => 'string',
        optional => 1,
    },
    digits => {
        description => "TOTP digits.",
        format_description => 'COUNT',
        type => 'integer',
        minimum => 6, maximum => 8,
        default => 6,
        optional => 1,
    },
    step => {
        description => "TOTP time period.",
        format_description => 'SECONDS',
        type => 'integer',
        minimum => 10,
        default => 30,
        optional => 1,
    },
};

PVE::JSONSchema::register_format('pve-tfa-config', $tfa_format);

PVE::JSONSchema::register_standard_option('tfa', {
    description => "Use Two-factor authentication.",
    type => 'string', format => 'pve-tfa-config',
    optional => 1,
    maxLength => 128,
});

sub parse_tfa_config {
    my ($data) = @_;

    return PVE::JSONSchema::parse_property_string($tfa_format, $data);
}

my $defaultData = {
    propertyList => {
	type => { description => "Realm type." },
	realm => get_standard_option('realm'),
    },
};

sub private {
    return $defaultData;
}

sub parse_section_header {
    my ($class, $line) = @_;

    if ($line =~ m/^(\S+):\s*(\S+)\s*$/) {
	my ($type, $realm) = (lc($1), $2);
	my $errmsg = undef; # set if you want to skip whole section
	eval { pve_verify_realm($realm); };
	$errmsg = $@ if $@;
	my $config = {}; # to return additional attributes
	return ($type, $realm, $errmsg, $config);
    }
    return undef;
}

sub parse_config {
    my ($class, $filename, $raw) = @_;

    my $cfg = $class->SUPER::parse_config($filename, $raw);

    my $default;
    foreach my $realm (keys %{$cfg->{ids}}) {
	my $data = $cfg->{ids}->{$realm};
	# make sure there is only one default marker
	if ($data->{default}) {
	    if ($default) {
		delete $data->{default};
	    } else {
		$default = $realm;
	    }
	}

	if ($data->{comment}) {
	    $data->{comment} = PVE::Tools::decode_text($data->{comment});
	}

    }

    # add default domains

    $cfg->{ids}->{pve}->{type} = 'pve'; # force type
    $cfg->{ids}->{pve}->{comment} = "Proxmox VE authentication server"
	if !$cfg->{ids}->{pve}->{comment};

    $cfg->{ids}->{pam}->{type} = 'pam'; # force type
    $cfg->{ids}->{pam}->{plugin} =  'PVE::Auth::PAM';
    $cfg->{ids}->{pam}->{comment} = "Linux PAM standard authentication"
	if !$cfg->{ids}->{pam}->{comment};

    return $cfg;
};

sub write_config {
    my ($class, $filename, $cfg) = @_;

    foreach my $realm (keys %{$cfg->{ids}}) {
	my $data = $cfg->{ids}->{$realm};
	if ($data->{comment}) {
	    $data->{comment} = PVE::Tools::encode_text($data->{comment});
	}
    }

    $class->SUPER::write_config($filename, $cfg);
}

sub authenticate_user {
    my ($class, $config, $realm, $username, $password) = @_;

    die "overwrite me";
}

sub store_password {
    my ($class, $config, $realm, $username, $password) = @_;

    my $type = $class->type();

    die "can't set password on auth type '$type'\n";
}

sub delete_user {
    my ($class, $config, $realm, $username) = @_;

    # do nothing by default
}

1;
