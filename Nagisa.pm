###
### Nagisa Default
###
package Nagisa::Settings;
use strict;
use warnings;
use base 'Class::Accessor::Fast';
use YAML::XS;
__PACKAGE__->mk_accessors(qw/
    _settings
/);

sub load {
    my ($class) = @_;
    my $self = $class->new();
    eval{
        $self->{_settings} = YAML::XS::LoadFile(
                $ENV{NAGISA_LIB_ROOT} . "/config/nagisa_config.yaml" );
    };
    if($@){
        $self->{_settings} = {
            template_prefix => '/tmpl/',
            cache_server    => [
                'localhost:11211',
            ],
            header_charset  => 'utf8',
            header_type     => 'text/html',
            session_expire  => '+5m',
        }
    }
    return $self;
};

sub TEMPLATE_PREFIX { 
    my $self = shift;
    return $ENV{NAGISA_PROJECT_ROOT}.$self->_settings->{template_prefix};
}
sub CACHE_SERVER    {  
    my $self = shift;
    return $self->_settings->{cache_server};
}
sub HEADER_CHARSET  { 
    my $self = shift;
    return $self->_settings->{header_charset};
}
sub HEADER_TYPE     { 
    my $self = shift;
    return $self->_settings->{header_type};
}
sub SESSION_EXPIRE  { 
    my $self = shift;
    return $self->_settings->{session_expire};
}

###
### Nagisa
###
package Nagisa;
use strict;
use warnings;
use base 'Class::Accessor::Fast';
use CGI;
use URI;
use File::Copy;
use FormValidator::Simple;
use Cache::Memcached::Fast; 
use CGI::Session qw/-ip_match/;
use CGI::Session::Driver::memcached;

__PACKAGE__->mk_accessors(qw/
    config
    stash
    cgi
    cache
    session
    template
    header
    postkey
    validation_rule
    validation_message
    validation_error
    mode
    assign 
    settings
/);

our %nagisa_class_property;

sub use_cache {
    my ($class,$flag) = @_;
    $nagisa_class_property{use_cache} = $flag || 0;
}
sub use_session {
    my ($class,$flag) = @_;
    $nagisa_class_property{use_session} = $flag || 0;
}

sub use_url_session_id {
    my ($class,$flag) = @_;
    $nagisa_class_property{use_url_session_id} = $flag || 0;
}

sub use_mode_param {
    my ($class,$mode_param_name) = @_;
    $nagisa_class_property{mode_param} = $mode_param_name || 0;
}

sub display {
    my ($class,%args) = @_;
    my $nagisa = $class->new();
    if($nagisa->can('init')){ 
        $nagisa->init();
    }
    if($nagisa->can('main')){ 
        $nagisa->main();
    }
    if(!$nagisa->mode 
       && $nagisa->config->{mode_param}){
        $nagisa->mode($nagisa->param->{
            $nagisa->config->{mode_param}
        });
    }
    my $assign_functions;
    if($nagisa->mode){
        $assign_functions = $nagisa->assign->{$nagisa->mode};
    }else{
        $assign_functions = $nagisa->assign->{_default};
    } 
    foreach my $function_ref (@{$assign_functions}){
        $nagisa->$function_ref;
    }
    $nagisa->header();
    $nagisa->template->output();
    return 1;
}

sub new {
    my ($class, $args) = @_;
    my $settings = Nagisa::Settings->load;
    my $self;
    $self = $class->SUPER::new({
            config   => {
                use_cache           => 
                    $nagisa_class_property{use_cache} || 0,
                use_session         => 
                    $nagisa_class_property{use_session} || 0,
                use_url_session_id  => 
                    $nagisa_class_property{use_url_session_id} || 0,
                mode_param          => 
                    $nagisa_class_property{mode_param} || undef,
            },
            stash    => {},
            cgi      => CGI->new(),
            cache    => undef,
            session  => undef,
            template => Nagisa::Template->new({
                file_prefix => $settings->TEMPLATE_PREFIX,
                }),
            header   => {
                charset => $settings->HEADER_CHARSET,
                type    => $settings->load->HEADER_TYPE,
            },
            postkey  => Nagisa::Postkey->new,
            validation_rule     => {},
            validation_message  => {},
            validation_error    => [],
            mode                => undef,
            assign              => {},
            settings            => $settings,
            });
    if($self->config->{use_cache}){
        $self->cache_connect;
    }
    if($self->config->{use_session}){
        $self->init_session;
    }
    return $self;
}

sub param {
    my $self = shift;
    return $self->cgi->Vars;
}

sub param_arrayref {
    my ($self,$param) = @_;
    my @result = $self->cgi->param($param);
    return \@result;
}

sub upload {
    my ($self,$param) = @_;
    return $self->cgi->upload($param);
}

sub store {
    my $self = shift;
    my %args = (
            param   => undef,
            path    => undef,
            @_);
    return unless $args{param};
    return unless $args{path};
    my $fh = $self->upload($args{param});
    return copy($fh,$args{path});
}

sub header {
    my $self = shift;
    my %header_param;
    $header_param{-charset} = $self->{header}->{charset};
    $header_param{-type}    = $self->{header}->{type};

    if($self->session && !$self->config->{use_url_session_id}){
        $header_param{-cookie} = $self->cgi->cookie(
                -name => 'SESSIONID',
                -value => $self->session->id,
                );
    }
    print $self->cgi->header(%header_param);
}

sub redirect {
    my ($self,$url) = @_;
    return unless $url;
    print $self->cgi->redirect($url);
    exit;
}

sub has_error {
    my ($self,$rule) = @_;
    $rule ||= '_default';
    my $filter = $self->{validation_rule}->{$rule};
    return unless $filter;
    FormValidator::Simple->set_messages($self->validation_message);
    my $result = FormValidator::Simple->check($self->cgi,$filter);
    $self->{validation_error} = $result->messages($rule);
#    $self->template->param(
#            validation_error => $self->validation_error,
#            );
    return $result->has_error;
}

sub url {
    my $self = shift;
    my ($path,$param) = @_;
    my $uri = URI->new($path);
    if($self->session && $self->config->{use_url_session_id}){
        $param->{SESSIONID} = $self->session->id;
    }
    $uri->query_form(%{$param});
    return $uri->as_string;
}

sub cache_connect {
    my ($self,$server) = @_;
    if($self->cache){
        return;
    }
    $server ||= $self->settings->CACHE_SERVER;
    $self->{cache} = Cache::Memcached::Fast->new({
            servers => $server,
            });
    return $self->cache;
}

sub init_session {
    my ($self) = @_;
    if($self->session){
        return;
    }
    my $session_id;
    if($self->config->{use_url_session_id}){
        $session_id = $self->param->{SESSIONID}
            || $self->cgi->cookie('SESSIONID')
            || undef;
    }else{
        $session_id = $self->cgi->cookie('SESSIONID')
            || $self->param->{SESSIONID}
            || undef;
    }
    $self->cache_connect;
    my $session = CGI::Session->new(
            'driver:memcached', 
            $session_id,
            { Memcached => $self->cache },
            );
    if(defined($session_id) && $session_id ne $session->id){
        warn "invalid session id. $session_id";
    }
    $session->expire($self->settings->SESSION_EXPIRE);
    $self->{session} = $session;
    return $self->session;
}
=hoge
sub url {
    my $self = shift;
    my ($base_url,$param) = @_;
    $base_url   ||= '';
    $param      ||= {};
    my $uri = URI->new($base_url);
    $uri->query_form(%{$param}); 
    return $uri->as_string;
}
=cut
sub query_string {
    my ($self,$param) = @_;
    my $url = $self->url('',$param);
    $url =~ s/\?//;
    return $url;

}

###
### Nagisa Template
###
package Nagisa::Template;
use strict;
use warnings;
use base 'Class::Accessor::Fast';
use HTML::Template;

__PACKAGE__->mk_accessors(qw/
    _param
    file
    file_prefix
/);

sub new {
    my ($class, $args) = @_;
    my $self;
    $self = $class->SUPER::new({
            _param       => {},
            file        => undef,
            file_prefix => $args->{file_prefix} || '',
            });
    return $self;
}

sub param {
    my ($self,$param) = @_;
    foreach my $key ( keys %{$param} ){
        $self->{_param}->{$key} = $param->{$key};
    }
}

sub output {
    my $self = shift;
    return unless $self->file;
    my $template_file = $self->file_prefix . $self->file;
    my $template = HTML::Template->new(
            filename            => $template_file,
            die_on_bad_params   => 0,
            cache               => 1,
            );
    $template->param(%{$self->_param});
    print $template->output;
}

###
### Nagisa Postkey
###
package Nagisa::Postkey;
use strict;
use warnings;
use base 'Class::Accessor::Fast';
use Digest::SHA1 qw(sha1_hex);

sub SALT        { 'nagisa_postkey_salt'}
sub RAND_MAX    { 100000000 };

sub create {
    my ($class) = shift;
    my $param_string = join(':',@_) || '';
    return sha1_hex($class->SALT . $param_string);
}

sub check {
    my ($class) = shift;
    my $postkey = shift;
    my @params  = @_;
    return unless $postkey;
    my @digest_param = split(/_/,$postkey);
    if(defined($digest_param[0]) 
        && $digest_param[0] eq 'digest'
        && defined($digest_param[1])
        && defined($digest_param[2]) ){
        @params = split(/:/,$digest_param[1]);
        $postkey = $digest_param[2];
    }
    my $param_string = join(':',@params) || '';
    if(sha1_hex($class->SALT . $param_string) eq $postkey){
        return 1;
    }else{
        return;
    }
}

sub create_digest {
    my ($class) = shift;
    my @params = @_;
    if(!scalar(@params)){
        my $rand = int(rand $class->RAND_MAX) + 1;
        @params = (sha1_hex($class->SALT . $rand));
    }
    my $param_string = join(':',@params) || '';
    my $signature = sha1_hex($class->SALT . $param_string);
    return 'digest_' . $param_string . "_" . $signature;
}

1;
