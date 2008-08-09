#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 172;

use lib qw(/opt/rt3/local/lib /opt/rt3/lib);
require RT::Test; import RT::Test;
require "t/rtir-test.pl";

{
    $RT::Handle->InsertSchema(undef, '/opt/rt3/local/etc/FM');
    $RT::Handle->InsertACL(undef, '/opt/rt3/local/etc/FM');

    $RT::Handle = new RT::Handle;
    $RT::Handle->dbh( undef );
    RT->ConnectToDatabase;

    local @INC = ('/opt/rt3/local/etc', '/opt/rt3/etc', @INC);
    RT->Config->LoadConfig(File => "IR/RTIR_Config.pm");
    $RT::Handle->InsertData('IR/initialdata');

    $RT::Handle = new RT::Handle;
    $RT::Handle->dbh( undef );
    RT->ConnectToDatabase;
}

RT::Test->set_mail_catcher;

RT->Config->Set( Plugins => 'RT::FM', 'RT::IR' );
RT::InitPluginPaths();
RT::InitPlugins();

use_ok('RT::IR');

my ($baseurl, $agent) = RT::Test->started_ok;
rtir_user();
$agent->login( rtir_test_user => 'rtir_test_pass' );

my $cf;
diag "load and check basic properties of the CF" if $ENV{'TEST_VERBOSE'};
{
    my $cfs = RT::CustomFields->new( $RT::SystemUser );
    $cfs->Limit( FIELD => 'Name', VALUE => '_RTIR_Constituency' );
    is( $cfs->Count, 1, "found one CF with name '_RTIR_Constituency'" );

    $cf = $cfs->First;
    is( $cf->Type, 'Select', 'type check' );
    is( $cf->LookupType, 'RT::Queue-RT::Ticket', 'lookup type check' );
    is( $cf->MaxValues, 1, "single value" );
    ok( !$cf->Disabled, "not disabled" );
}

diag "check that CF applies to all RTIR's queues" if $ENV{'TEST_VERBOSE'};
{
    foreach ( 'Incidents', 'Incident Reports', 'Investigations', 'Blocks' ) {
        my $queue = RT::Queue->new( $RT::SystemUser );
        $queue->Load( $_ );
        ok( $queue->id, 'loaded queue '. $_ );
        my $cfs = $queue->TicketCustomFields;
        $cfs->Limit( FIELD => 'id', VALUE => $cf->id, ENTRYAGGREGATOR => 'AND' );
        is( $cfs->Count, 1, 'field applies to queue' );
    }
}

my @constituencies;
diag "fetch list of constituencies and check that groups exist" if $ENV{'TEST_VERBOSE'};
{
    @constituencies = map $_->Name, @{ $cf->Values->ItemsArrayRef };
    ok( scalar @constituencies, "field has some predefined values" );
    foreach ( @constituencies ) {
        my $group = RT::Group->new( $RT::SystemUser );
        $group->LoadUserDefinedGroup( 'DutyTeam '. $_ );
        ok( $group->id, "loaded group for $_ constituency" );
    }
}

diag "check that there is no option to set 'no value' on create" if $ENV{'TEST_VERBOSE'};
{
    my $default = RT->Config->Get('_RTIR_Constituency_default');
    foreach my $queue( 'Incidents', 'Incident Reports', 'Investigations', 'Blocks' ) {
        diag "'$queue' queue" if $ENV{'TEST_VERBOSE'};

        goto_create_rtir_ticket( $agent, $queue );

        my $value = $agent->form_number(3)->value("Object-RT::Ticket--CustomField-". $cf->id ."-Values");
        is lc $value, lc $default, 'correct value is selected';

        my @values = $agent->form_number(3)->param("Object-RT::Ticket--CustomField-". $cf->id ."-Values");
        ok !grep( $_ eq '', @values ), 'have no empty value for selection';
    }
}

diag "create a ticket via web and set field" if $ENV{'TEST_VERBOSE'};
{
    # we skip blocks here, as they are always connected to
    # an incident and constituency inheritance comes into game
    foreach my $queue( 'Incidents', 'Incident Reports', 'Investigations' ) {
        diag "create a ticket in the '$queue' queue" if $ENV{'TEST_VERBOSE'};

        my $val = 'GOVNET';
        my $id = create_rtir_ticket_ok(
            $agent, $queue,
            { Subject => "test ip" },
            { Constituency => $val },
        );

        display_ticket($agent, $id);
        $agent->content_like( qr/\Q$val/, "value on the page" );
        DBIx::SearchBuilder::Record::Cachable::FlushCache();

        my $ticket = RT::Ticket->new( $RT::SystemUser );
        $ticket->Load( $id );
        ok( $ticket->id, 'loaded ticket' );
        is( $ticket->FirstCustomFieldValue('_RTIR_Constituency'), $val, 'correct value' );

diag "check that we can edit value" if $ENV{'TEST_VERBOSE'};
        $agent->follow_link( text => 'Edit' );
        $agent->content_like(qr/Constituency/, 'CF on the page');

        my $value = $agent->form_number(3)->value("Object-RT::Ticket-$id-CustomField-". $cf->id ."-Values");
        is lc $value, 'govnet', 'correct value is selected';

        $val = 'EDUNET';
        $agent->select("Object-RT::Ticket-$id-CustomField-". $cf->id ."-Values" => $val );
        $agent->click('SaveChanges');
        $agent->content_like(qr/Constituency .* changed to \Q$val/mi, 'field is changed') or diag $agent->content;
        DBIx::SearchBuilder::Record::Cachable::FlushCache();

        $ticket = RT::Ticket->new( $RT::SystemUser );
        $ticket->Load( $id );
        ok( $ticket->id, 'loaded ticket' );
        is( lc $ticket->FirstCustomFieldValue('_RTIR_Constituency'), lc $val, 'correct value' );
    }
}

my $eduhandler = RT::Test->load_or_create_user( Name => 'eduhandler', Password => 'eduhandler' );
ok $eduhandler->id, "Created eduhandler";

my $govhandler = RT::Test->load_or_create_user( Name => 'govhandler', Password => 'govhandler' );
ok $govhandler->id, "Created govhandler";

my $ir_queue = RT::Test->load_or_create_queue(
    Name => 'Incident Reports',
);
ok $ir_queue->id, "loaded or created queue";

ok( RT::Test->add_rights(
    { Principal => 'Privileged', Right => [qw(ModifyCustomField SeeCustomField)], },
), 'set rights');

foreach my $name('Incident Reports', 'Incidents', 'Investigations', 'Blocks' ) {
    my $queue = RT::Test->load_or_create_queue(
        Name => "$name",
        CorrespondAddress => 'rt@example.com',
    );
    ok $queue->id, "loaded or created queue";
    ok( RT::Test->add_rights(
        { Principal => $eduhandler, Object => $queue, Right => [qw(SeeQueue CreateTicket)] },
        { Principal => $govhandler, Object => $queue, Right => [qw(SeeQueue CreateTicket)] },
    ), 'set rights');

    $queue = RT::Test->load_or_create_queue(
        Name => "$name - EDUNET",
        CorrespondAddress => 'edunet@example.com',
    );
    ok $queue->id, "loaded or created queue";
    ok( RT::Test->add_rights(
        { Principal => $eduhandler, Object => $queue, Right => [qw(ShowTicket CreateTicket OwnTicket)] },
    ), 'set rights');
    ok($queue->HasRight(Principal => $eduhandler, Right => 'ShowTicket'), "eduhnadler can see edutix"); 
    ok(!$queue->HasRight(Principal => $govhandler, Right => 'ShowTicket'), "govhnadler can not see edutix"); 

    $queue = RT::Test->load_or_create_queue(
        Name => "$name - GOVNET",
        CorrespondAddress => 'govnet@example.com',
    );
    ok $queue->id, "loaded or created queue";
    ok( RT::Test->add_rights(
        { Principal => $govhandler, Object => $queue, Right => [qw(ShowTicket CreateTicket OwnTicket)] },
    ), 'set rights');
    ok(!$queue->HasRight(Principal => $eduhandler, Right => 'ShowTicket'), "eduhnadler can not see edutix"); 
    ok($queue->HasRight(Principal => $govhandler, Right => 'ShowTicket'), "govhnadler can see edutix"); 
}

diag "Create an incident report with a default constituency of EDUNET" if $ENV{'TEST_VERBOSE'};


    my $val = 'EDUNET';
    my $ir_id = create_ir(
        $agent, { Subject => "test" }, { Constituency => $val }
    );
    ok( $ir_id, "created IR #$ir_id" );
    display_ticket($agent, $ir_id);
    $agent->content_like(qr/EDUNET/, "It was created by edunet");

diag "autoreply comes from the EDUNET queue address" if $ENV{'TEST_VERBOSE'};
my $ticket = RT::Ticket->new($RT::SystemUser);
$ticket->Load($ir_id);
$ticket->AddWatcher(Type => 'Requestor', Email => 'enduser@example.com');
$ticket->Correspond(Content => 'Testing');
my $txns = $ticket->Transactions;
$txns->Limit( FIELD => 'Type', VALUE => 'EmailRecord' );
ok $txns->Count, 'we have at least one email record';

my $from_ok = 1;
while ( my $txn = $txns->Next ) {
    my $from = $txn->Attachments->First->GetHeader('From');
    next if $from =~ /edunet/;

    $from_ok = 0;
    last;
}
ok $from_ok, "The from address picked up the edunet address";


diag "govhandler can't see the incident report"       if $ENV{'TEST_VERBOSE'};
my $ticket_as_gov = RT::Ticket->new($govhandler);
$ticket_as_gov->Load($ir_id);
is($ticket_as_gov->Subject,undef, "As the gov handler, I can not see the ticket");


diag "eduhandler can see the incident report"         if $ENV{'TEST_VERBOSE'};
my $ticket_as_edu = RT::Ticket->new($eduhandler);
$ticket_as_edu->Load($ir_id);
is($ticket_as_edu->Subject, 'test', "As the edu handler, I can see the ticket");




diag "move the incident report from EDUNET to GOVNET" if $ENV{'TEST_VERBOSE'};
{
    display_ticket($agent, $ir_id);
    $agent->follow_link_ok({text => 'Edit'}, "go to Edit page");
    $agent->form_number(3);
    ok(set_custom_field( $agent, Constituency => 'GOVNET' ), "fill value in the form");
    $agent->click('SaveChanges');
    is( $agent->status, 200, "Attempting to edit ticket #$ir_id" );
    $agent->content_like( qr/GOVNET/, "value on the page" );

    DBIx::SearchBuilder::Record::Cachable::FlushCache();
        $RT::IR::ConstituencyCache{$ir_id}  = undef;
}

diag "govhandler can see the incident report"         if $ENV{'TEST_VERBOSE'};
$ticket_as_gov = RT::Ticket->new($govhandler);
$ticket_as_gov->Load($ir_id);
is($ticket_as_gov->Subject, 'test',"As the gov handler, I can see the ticket");

diag "eduhandler can't see the incident report"       if $ENV{'TEST_VERBOSE'};
 
$ticket_as_edu = RT::Ticket->new($eduhandler);
$ticket_as_edu->Load($ir_id);
is($ticket_as_edu->Subject,undef , "As the edu handler, I can not see the ticket");

diag "govhandler replies to the incident report" if $ENV{'TEST_VERBOSE'};
$ticket_as_gov->Correspond(Content => 'Testing 2');
diag "reply comes from the GOVNET queue address" if $ENV{'TEST_VERBOSE'};
{
my $txns = $ticket->Transactions;
my $from;
while (my $txn = $txns->Next) {
    next unless ($txn->Type eq 'EmailRecord');
    $from = $txn->Attachments->First->GetHeader('From');
}
ok($from =~ /govnet/, "The from address pciked up the gov address");

}

diag "check defaults";
{
    $agent->login('eduhandler', 'eduhandler');
    my $ir_id = create_ir(
        $agent, { Subject => "test" },
    );
    my $ticket = RT::Ticket->new($RT::SystemUser);
    $ticket->Load($ir_id);
    is( $ticket->FirstCustomFieldValue('_RTIR_Constituency'), 'EDUNET', 'correct value' );
}

diag "check defaults";
{
    $agent->login('govhandler', 'govhandler');
    my $ir_id = create_ir(
        $agent, { Subject => "test" },
    );
    my $ticket = RT::Ticket->new($RT::SystemUser);
    $ticket->Load($ir_id);
    is( $ticket->FirstCustomFieldValue('_RTIR_Constituency'), 'GOVNET', 'correct value' );
}

diag "check defaults when creating inc with inv";
{
    $agent->login('govhandler', 'govhandler');
	my ($inc_id, $inv_id) = create_incident_and_investigation(
        $agent, 
	    {
            Subject => "Incident", 
		    InvestigationSubject => "Investigation",
		    InvestigationRequestors => 'requestor@example.com',
        },
    );
    {
        my $ticket = RT::Ticket->new($RT::SystemUser);
        $ticket->Load($inc_id);
        is( $ticket->FirstCustomFieldValue('_RTIR_Constituency'), 'GOVNET', 'correct value' );
    } {
        my $ticket = RT::Ticket->new($RT::SystemUser);
        $ticket->Load($inv_id);
        is( $ticket->FirstCustomFieldValue('_RTIR_Constituency'), 'GOVNET', 'correct value' );
    }
}

diag "check defaults when creating inc with inv";
{
    $agent->login('eduhandler', 'eduhandler');
	my ($inc_id, $inv_id) = create_incident_and_investigation(
        $agent, 
	    {
            Subject => "Incident", 
		    InvestigationSubject => "Investigation",
		    InvestigationRequestors => 'requestor@example.com',
        },
    );
    {
        my $ticket = RT::Ticket->new($RT::SystemUser);
        $ticket->Load($inc_id);
        is( $ticket->FirstCustomFieldValue('_RTIR_Constituency'), 'EDUNET', 'correct value' );
    } {
        my $ticket = RT::Ticket->new($RT::SystemUser);
        $ticket->Load($inv_id);
        is( $ticket->FirstCustomFieldValue('_RTIR_Constituency'), 'EDUNET', 'correct value' );
    }
}

