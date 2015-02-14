=pod
Perpetually Against Humanity, IRC Edition (pah-irc)

Play endless games of Cards Against Humanity on IRC.

https://github.com/grifferz/pah-irc

This code:
    Copyright ©2015 Andy Smith <andy-pah-irc@strugglers.net>

    Artistic license same as Perl.

Get Cards Against Humanity here!
    http://cardsagainsthumanity.com/

    Cards Against Humanity content is distributed under a Creative Commons
    BY-NC-SA 2.0 license. Cards Against Humanity is a trademark of Cards
    Against Humanity LLC.
=cut

package PAH;
our $VERSION = "0.1";

use utf8; # There's some funky literals in here
use Config::Tiny;
use strict;
use warnings;
use Moose;
use MooseX::Getopt;
with 'MooseX::Getopt';
use Try::Tiny;
use List::Util qw/shuffle/;

use Data::Dumper;

use PAH::IRC;
use PAH::Log;
use PAH::Schema;
use PAH::Deck;

has config_file => (
    isa     => 'Str',
    is      => 'ro',
    default => sub { "etc/pah-irc.conf" }
);

has ircname => (
    isa     => 'Str',
    is      => 'ro',
    default => sub { "pah-irc $VERSION" }
);

has _config => (
    isa     => 'HashRef',
    is      => 'ro',
);

has _irc => (
    isa     => 'PAH::IRC',
    is      => 'ro',
    default => sub { PAH::IRC->new }
);

has _schema => (
    isa => 'PAH::Schema',
    is  => 'ro',
);

has _pub_dispatch => (
    is => 'ro',
);

has _priv_dispatch => (
    is => 'ro',
);

has _whois_queue => (
    is => 'ro',
);

has _deck => (
    is => 'ro',
);

has _plays => (
    is => 'ro',
);

sub BUILD {
  my ($self) = @_;

  my $config = Config::Tiny->read($self->config_file)
      or die Config::Tiny->errstr;
  # Only care about the root section for now.
  $self->{_config} = $config->{_};

  $self->{_pub_dispatch} = {
      'status'      => {
          sub        => \&do_pub_status,
          privileged => 0,
      },
      'start'       => {
          sub        => \&do_pub_start,
          privileged => 1,
      },
      'me'  => {
          sub       => \&do_pub_dealin,
          privileged => 1,
      },
      'me!'  => {
          sub       => \&do_pub_dealin,
          privileged => 1,
      },
      'deal me in'  => {
          sub       => \&do_pub_dealin,
          privileged => 1,
      },
      'resign'      => {
          sub        => \&do_pub_resign,
          privileged => 1,
      },
      'deal me out' => {
          sub        => \&do_pub_resign,
          privileged => 1,
      },
  };

  $self->{_priv_dispatch} = {
      'hand' => {
          sub        => \&do_priv_hand,
          privileged => 1,
      },
      'black' => {
          sub        => \&do_priv_black,
          privileged => 0,
      },
      'play' => {
          sub        => \&do_priv_play,
          privileged => 1,
      },
  };

  $self->{_whois_queue} = {};

  my $default_deck = 'cah_uk';

  $self->{_deck} = PAH::Deck->load($default_deck);

  my $deck = $self->{_deck}->{$default_deck};

  debug("Loaded deck: %s", $deck->{Description});
  debug("Deck has %u Black Cards, %u White Cards",
      scalar @{ $deck->{Black} }, scalar @{ $deck->{White} });

  $self->{_plays} = {};
}

# The "main"
sub start {
    my ($self) = @_;

    $self->db_connect;

    try {
        $self->connect;
        AnyEvent->condvar->recv;
    } catch {
        # Just the first line, Moose can spew rather long errors.
        $self->_irc->disconnect("Died: " . (/^(.*)$/m)[0]);
        warn $_;
    };
}

sub db_connect {
    my ($self) = @_;

    my $c = $self->_config;

    my $dbfile = $c->{dbfile};

    if (not defined $dbfile) {
        die "Config item 'dbfile' must be specified\n";
    }

    if (! -w $dbfile) {
        die "SQLite database $dbfile isn't writable\n";
    }

    $self->{_schema} = PAH::Schema->connect("dbi:SQLite:$dbfile", '', '',
        { sqlite_unicode => 1 });
}

sub shutdown {
  my ($self) = @_;

  $self->_irc->disconnect("Shutdown");
}

sub handle_sighup {
  my ($self) = @_;
}

sub connect {
    my ($self) = @_;
    my $c = $self->_config;

    $self->_irc->connect($self,
        $c->{target_server}, $c->{target_port},
        {
            nick      => $c->{nick},
            nick_pass => $c->{nick_pass},
            user      => $c->{username},
            real      => $self->ircname,
            password  => $self->{target_pass},
        }
    );
}

sub joined {
    my($self, $chan) = @_;

    my $name   = lc($chan);
    my $schema = $self->_schema;

    debug("Joined %s", $chan);

    # Is there a game for this channel already in existence?
    my $channel = $schema->resultset('Channel')->find({ name => $name });

    return unless (defined $channel);

    my $game = $channel->rel_game;

    return unless (defined $game);

    debug("%s appears to have a game in existence…", $chan);

    if (0 == $game->status) {
        debug("…and it's currently paused so I'm going to activate it");

        my $num_players = scalar $game->rel_active_usergames;

        if ($num_players < 4) {
            $game->status(1); # Waiting for players.
            debug("Game for %s only had %u player(s) so I set it as"
               . " waiting", $chan, $num_players);
        } else {
            $game->status(2); # We're on.
            debug("Game for %s has enough players so it's now active",
                $chan);
        }

        $game->update;
    } else {
        my $status_txt;

        if (1 == $game->status) {
            $status_txt = "waiting for players";
        } elsif (2 == $game->status) {
            $status_txt = "running";
        } else {
            $status_txt = "in an invalid state";
        }

        debug("…but it's currently %s, so I won't do anything about that",
            $status_txt);
    }
}

# Mark a channel as no longer welcoming, for whatever reason. Usually because
# we just got kicked out of it.
sub mark_unwelcome {
    my ($self, $chan) = @_;

    my $schema = $self->_schema;

    # Downcase channel names for storage.
    my $name = lc($chan);

    my $channel = $schema->resultset('Channel')->find({ name => $name });

    if (defined $channel) {
        $channel->welcome(0);
        $channel->update;
        debug("Marked %s as unwelcoming", $chan);

        # Now mark any associated game as paused.
        if (defined $channel->rel_game) {
            $channel->rel_game->status(0); # Paused.
            $channel->rel_game->activity_time(time());
            $channel->rel_game->update;
            debug("Game for %s is now paused", $chan);
        }
    } else {
        debug("Tried to mark %s as unwelcoming but couldn't find it in the"
           . " database!", $name);
   }
}

# Mark a channel as welcome, creating it in the database in the process if
# necessaary.
sub create_welcome {
    my ($self, $chan) = @_;

    my $schema = $self->_schema;

    # Downcase channel names for storage.
    my $name = lc($chan);

    my $channel = $schema->resultset('Channel')->update_or_new(
        {
            name      => $name,
            disp_name => $chan,
            welcome   => 1,
        }
    );

    if ($channel->in_storage) {
        # The channel was already there and was only updated.
        debug("I'm now welcome in %s", $chan);
    } else {
        # This is a new row and needs actually populating.
        $channel->insert;
        debug("I'm now welcome in new channel %s", $chan);
    }
}

# Try to join all the channels from our database that we know are welcoming
# towards our presence.
sub join_welcoming_channels {
    my ($self) = @_;

    my $schema = $self->_schema;

    my $welcoming_chans = $schema->resultset('Channel')->search(
        {
            welcome => 1,
        }
    );

    for my $channel ($welcoming_chans->all) {
        debug("Looks like I'm welcome in %s; joining…", $channel->disp_name);
        $self->_irc->send_srv(JOIN => $channel->name);
    }
}

# Deal with a possible command directed at us in private message.
sub process_priv_command {
    my ($self, $sender, $cmd) = @_;

    # Downcase everything, even the command, as there currently aren't any
    # private commands that could use mixed case.
    $sender = lc($sender);
    $cmd    = lc($cmd);

    my $chan = undef;
    my $rest = undef;

    my $disp = $self->_priv_dispatch;

    # Does the command have a channel specified?
    #
    # Private commands look like this:
    #
    # some_command
    # some_command and some arguments
    # #foo some_command
    # #foo some_command and some arguments
    #
    #
    # The first asks to perform "some_command" in the single game that the user
    # is active in. This will be an error if the user is active in multiple
    # games.
    #
    # The second specifies that the command relates to the game being carried
    # out in channel #foo, which removes the ambiguity.
    if ($cmd =~ /^([#\&]\S+)\s+(\S+)(.*)?$/) {
        $chan = $1;
        $cmd  = $2;
        $rest = $3;
    } elsif ($cmd =~ /^\s*(\S+)(.*)?$/) {
        $cmd  = $1;
        $rest = $2;
    }

    # Strip off any leading/trailing whitespace.
    if (defined $rest) {
        $rest =~ s/^\s+//;
        $rest =~ s/\s+$//;
    };

    my $args = {
        nick   => $sender,
        chan   => $chan,
        public => 0,
        params => $rest,
    };

    if (exists $disp->{$cmd}) {
        if (0 == $disp->{$cmd}->{privileged}) {
            # This is an unprivileged command that anyone may use, so just
            # dispatch it.
            $disp->{$cmd}->{sub}->($self, $args);
        } else {
            # This command requires the user to be identified to a registered
            # nickname. We'll ensure this by:
            #
            # 1. Storing the details onto a queue.
            # 2. Issuing a WHOIS for the user.
            # 3. Checking the queue when we receive a WHOIS reply, later.
            # 4. Executing the callback at that time if appropriate.
            queue_whois_callback($self,
                {
                    target   => $args->{nick},
                    callback => $disp->{$cmd},
                    cb_args  => $args,
                }
            );
        }
    } else {
        do_unknown($self, $args);
    }
}

# Deal with a public command directed at us in a channel.
sub process_chan_command {
    my ($self, $sender, $chan, $cmd) = @_;

    # Downcase everything, even the command, as there currently aren't any
    # public commands that could use mixed case.
    $sender = lc($sender);
    $chan   = lc($chan);
    $cmd    = lc($cmd);

    my $disp = $self->_pub_dispatch;
    my $args = {
        nick   => $sender,
        chan   => $chan,
        public => 1,
    };

    if (exists $disp->{$cmd}) {
        if (0 == $disp->{$cmd}->{privileged}) {
            # This is an unprivileged command that anyone may use, so just
            # dispatch it.
            $disp->{$cmd}->{sub}->($self, $args);
        } else {
            # This command requires the user to be identified to a registered
            # nickname. We'll ensure this by:
            #
            # 1. Storing the details onto a queue.
            # 2. Issuing a WHOIS for the user.
            # 3. Checking the queue when we receive a WHOIS reply, later.
            # 4. Executing the callback at that time if appropriate.
            queue_whois_callback($self,
                {
                    target   => $args->{nick},
                    channel  => $chan,
                    callback => $disp->{$cmd},
                    cb_args  => $args,
                }
            );
        }
    } else {
        do_unknown($self, $args);
    }
}

# Issue a 'whois' command with a callback function that will be executed
# provided that the results of the whois are as expected. This is going to
# check for the services account info being present.
sub queue_whois_callback {
    my ($self, $cb_info) = @_;

    my $irc         = $self->_irc;
    my $whois_queue = $self->_whois_queue;
    my $time        = time();
    my $target      = $cb_info->{target};

    my $queue_entry = {
        info      => $cb_info,
        timestamp => $time,
    };

    # The WHOIS queue is a hash of lists keyed off the nickname.
    # Initialise the queue for the target nickname to the empty list, if it
    # doesn't already exist.
    $whois_queue->{$target} = [] if (not exists $whois_queue->{$target});

    my $queue = $whois_queue->{$target};

    debug("Queueing a WHOIS callback against %s", $target);

    push(@{ $queue }, $queue_entry);

    $irc->send_srv(WHOIS => $target);
}

sub execute_whois_callback {
    my ($self, $item) = @_;

    my $callback = $item->{info}->{callback};
    my $cb_args  = $item->{info}->{cb_args};

    # Execute it.
    $callback->{sub}->($self, $cb_args);
}

sub denied_whois_callback {
    my ($self, $item) = @_;

    my $callback = $item->{info}->{callback};
    my $cb_args  = $item->{info}->{cb_args};
    my $chan     = $item->{info}->{channel};
    my $nick     = $item->{info}->{target};

    if (defined $chan) {
        # Callback was related to a channel.
        $self->_irc->msg($chan,
            "$nick: Sorry, you need to be identified to a registered nickname"
           . " to do that. Try again after identifying to Services.");
    } else {
        $self->_irc->msg($nick,
            "Sorry, you need to be identified to a registered nickname to do"
           . " that. Try again after identifying to Services.");
    }
}

# Didn't match any known command.
sub do_unknown {
    my ($self, $args) = @_;

    my $chan = $args->{chan};
    my $who  = $args->{nick};

    my $target;

    # Errors to go to the channel if the command came from the channel,
    # otherwise in private to the sender.
    if (1 == $args->{public}) {
        $target = $chan;
    } else {
        $target = $who;
    }

    if (defined $chan) {
        $self->_irc->msg($target,
            "$who: Sorry, that's not a command I recognise. See"
            . " https://github.com/grifferz/pah-irc#usage for more info.");
    } else {
        $self->_irc->msg($target,
            "Sorry, that's not a command I recognise. See"
           . " https://github.com/grifferz/pah-irc#usage for more info.");
    }
}

sub do_pub_status {
    my ($self, $args) = @_;

    my $chan   = $args->{chan};
    my $who    = $args->{nick};
    my $schema = $self->_schema;

    my $channel = $self->db_get_channel($chan);

    if (not defined $channel) {
        $self->_irc->msg($chan,
            "$who: Sorry, I don't seem to have $chan in my database, which is"
           . " a weird error that needs to be reported!");
       return;
    }

    my $my_nick = $self->_irc->nick();

    my $game = $channel->rel_game;

    if (not defined $game) {
        # There's never been a game in this channel.
        $self->_irc->msg($chan,
            "$who: There's no game of Perpetually Against Humanity in here.");
        $self->_irc->msg($chan,
            "Want to start one? Anyone with a registered nickname can do so.");
        $self->_irc->msg($chan,
            "Just type \"$my_nick: start\" and find at least 3 friends.");
    } elsif (2 == $game->status) {
        my @active_usergames = $game->rel_active_usergames;

        my ($tsar) = grep { 1 == $_->is_tsar } @active_usergames;

        $self->_irc->msg($chan,
            "$who: A game is active! We're currently waiting on NOT"
           . " IMPLEMENTED to NOT IMPLEMENTED.");
        $self->_irc->msg($chan,
            sprintf("The current Card Tsar is %s", $tsar->rel_user->nick));

        @active_usergames = sort {
            $b->wins <=> $a->wins
        } @active_usergames;

        my $winstring = join(' ',
            map { $_->rel_user->nick . '(' . $_->wins . ')' }
            @active_usergames);

        $self->_irc->msg($chan, "Active Players: $winstring");

        my @top3 = $schema->resultset('UserGame')->search(
            {},
            {
                join     => 'rel_user',
                prefetch => 'rel_user',
                order_by => 'wins DESC',
                rows     => 3,
            },
        );

        $winstring = join(' ',
            map { $_->rel_user->nick . '(' . $_->wins . ')' }
            @top3);

        $self->_irc->msg($chan, "Top 3 all time: $winstring");
        $self->_irc->msg($chan, "Current Black Card:");
        $self->notify_bcard($chan, $game);
    } elsif (1 == $game->status) {
        my $num_players = scalar $game->rel_active_usergames;

        $self->_irc->msg($chan,
            "$who: A game exists but we only have $num_players player"
            . (1 == $num_players ? '' : 's') . ". Find me "
            . (4 - $num_players) . " more and we're on.");
        $self->_irc->msg($chan,
            "Any takers? Just type \"$my_nick: me\" and you're in.");
    } elsif (0 == $game->status) {
        $self->_irc->msg($chan,
            "$who: The game is paused but I don't know why! Report this!");
    } else {
        debug("Game for %s has an unexpected status (%u)", $chan,
            $game->status);
        $self->_irc->msg($chan,
            "$who: I'm confused about the state of the game, sorry. Report"
           . " this!");
    }
}

# User wants to start a new game in a channel.
sub do_pub_start {
    my ($self, $args) = @_;

    my $chan    = $args->{chan};
    my $who     = $args->{nick};
    my $my_nick = $self->_irc->nick();
    my $schema  = $self->_schema;

    # Do we have a channel in the database yet? The only way to create a
    # channel is to be invited there, so there will not be any need to create
    # it here, and it's a weird error to not have it.
    my $channel = $self->db_get_channel($chan);

    if (not defined $channel) {
        $self->_irc->msg($chan,
            "$who: Sorry, I don't seem to have $chan in my database, which is"
           . " a weird error that needs to be reported!");
       return;
    }

    # Is there already a game for this channel?
    my $game = $channel->rel_game;

    if (defined $game) {
        # There's already a Game for this Channel. It could be in one of three
        # possible states:
        #
        # 0: Paused for an unknown reason.
        # 1: Waiting for a sufficient number of players.
        # 2: Running.
        #
        # Whatever the case, this is not the place where it can be started:
        #
        # * Paused games should be started as soon as the bot joins a welcoming
        #   channel.
        #
        # * Games without enough players will start as soon as they get enough
        #   players.
        #
        # * Running games don't need to be started!
        #
        # So apart from explanatory messages this isn't going to do anything.
        my $status = $game->status;

        if (0 == $status) {
            $self->_irc->msg($chan,
                "$who: Sorry, there's already a game for this channel, though"
               . " it seems to be paused when it shouldn't be! Ask around?");
        } elsif (1 == $status) {
            my $count = scalar ($game->rel_active_usergames);

            $self->_irc->msg($chan,
                "$who: Sorry, there's already a game here but we only have"
               . " $count of minimum 4 players. Does anyone else want to"
               . " play?");
            $self->_irc->msg($chan,
                "Type \"$my_nick: me\" if you'd like to!");
        } elsif (2 == $status) {
            $self->_irc->msg($chan,
                 "$who: Sorry, there's already a game running here!");
        }

        return;
    }

    # Need to create a new Game for this Channel. The User corresponding to the
    # nickname will be its first player. The initial status of the game will be
    # "waiting for players."
    $game = $schema->resultset('Game')->create(
        {
            channel       => $channel->id,
            create_time   => time(),
            activity_time => time(),
            status        => 1,
        }
    );

    # Seems to be necessary in order to get the default DB values back into the
    # object.
    $game->discard_changes;

    # Stuff the cards from memory structure into the database so that this game
    # has its own unique deck to work through, that will persist across process
    # restarts.
    $self->db_populate_cards($game);

    my $user = $self->db_get_user($who);

    # "Let the User see the Game!" Ahem. Add the User to the Game.
    # In the absence of being able to know who pooped last, the starting user
    # will be the first Card Tsar.
    my $usergame = $schema->resultset('UserGame')->create(
        {
            user      => $user->id,
            game      => $game->id,
            is_tsar   => 1,
            tsarcount => 1,
            active    => 1,
        }
    );

    # Now tell 'em.
    $self->_irc->msg($chan,
        "$who: You're on! We have a game of Perpetually Against Humanity up in"
       . " here. 4 players minimum are required. Who else wants to play?");
    $self->_irc->msg($chan,
        "Say \"$my_nick: me\" if you'd like to!");
}

# A user wants to join a (presumably) already-running game. This can happen
# from either of the following scenarios:
#
# <foo> AgainstHumanity: start
# <AgainstHumanity> foo: You're on! We have a game of Perpetually Against
#                   Humanity up in here. 4 players minimum are required. Who
#                   else wants to play?
# <AgainstHumanity> Say "AgainstHumanity: me" if you'd like to!
# <bar> AgainstHumanity: me!
#
# or:
#
# <bar> AgainstHumanity: deal me in.
sub do_pub_dealin {
    my ($self, $args) = @_;

    my $chan    = $args->{chan};
    my $who     = $args->{nick};
    my $schema  = $self->_schema;
    my $my_nick = $self->_irc->nick();

    my $channel = $self->db_get_channel($chan);

    if (not defined $channel) {
        $self->_irc->msg($chan,
            "$who: I can't seem to find a Channel object for this channel."
           . " That's weird and shouldn't happen. Report this!");
        return;
    }

    my $game = $channel->rel_game;

    # Is there a game running already?
    if (not defined $game) {
        # No, there is no game.
        #
        # This raises the question of whether we should treat a user asking to
        # be dealt in to a non-existent game as request to start the game
        # itself.
        #
        # I'm leaning towards "no" because the fact that the channel doesn't
        # already have a game running may hint towards the norms of the channel
        # being that games aren't welcome.
        $self->_irc->msg($chan,
            "$who: Sorry, there's no game here to deal you in to. Want to start"
           . " one?");
       $self->_irc->msg($chan,
            "$who: If so, type \"$my_nick: start\"");
        return;
    }

    my $user = $schema->resultset('User')->find_or_create(
        { nick => $who },
    );

    my @active_usergames = $game->rel_active_usergames;

    # Are they already in it?
    if (defined $game->rel_active_usergames
            and grep $_->id == $user->id, @active_usergames) {
        $self->_irc->msg($chan, "$who: Heyyy, you're already playing!");
        return;
    }

    # Maximum 20 players in a game.
    my $num_players = scalar @active_usergames;

    if ($num_players >= 20) {
        $self->_irc->msg($chan,
            "$who: Sorry, there's already $num_players players in this game and"
           . " that's the maximum. Try again once someone has resigned!");
        return;
    }

    # "Let the User see the Game!" Ahem. Add the User to the Game.
    my $usergame = $schema->resultset('UserGame')->update_or_create(
        {
            user   => $user->id,
            game   => $game->id,
            active => 1,
        }
    );

    # Update Channel activity timer.
    $game->activity_time(time());
    $game->update;

    $self->_irc->msg($chan, "$who: Nice! You're in!");

    # Does the game have enough players to start yet?
    $num_players = scalar $game->rel_active_usergames;

    if ($num_players >= 4 and 1 == $game->status) {
        $game->status(2);
        $game->update;
        $self->_irc->msg($chan,
            "The game begins! Give me a minute or two to tell everyone their hands"
           . " without flooding myself off, please.");
        # Get a chat window open with all the players.
        $self->brief_players($game);
        # Top everyone's White Card hands up to 10 cards.
        $self->topup_hands($game);
        # And deal out a Black Card to the Tsar.
        $self->deal_to_tsar($game);
    } else {
        $self->_irc->msg($chan,
            "We've now got $num_players of minimum 4. Anyone else?");
        $self->_irc->msg($chan,
            "Type \"$my_nick: me\" if you'd like to play too.");
    }
}

# A user wants to resign from the game. If they are the current round's Card
# Tsar then they aren't allowed to resign. Otherwise, their White Cards
# (including any that were already played in this round) are discarded and they
# are removed from the running game.
#
# If this brings the number of players below 4 then the game will be paused.
#
# The player can rejoin ther game at a later time.
sub do_pub_resign {
    my ($self, $args) = @_;

    my $chan    = $args->{chan};
    my $who     = $args->{nick};
    my $schema  = $self->_schema;
    my $my_nick = $self->_irc->nick();

    my $channel = $self->db_get_channel($chan);

    if (not defined $channel) {
        $self->_irc->msg($chan,
            "$who: I can't seem to find a Channel object for this channel."
            . " That's weird and shouldn't happen. Report this!");
        return;
    }

    my $game = $channel->rel_game;

    # Is there a game actually running?
    if (not defined $game) {
        $self->_irc->msg($chan,
            "$who: There isn't a game running at the moment.");
        return;
    }

    my $user = $schema->resultset('User')->find_or_create(
        { nick => $who },
    );

    my $usergame = $schema->resultset('UserGame')->find(
        {
            'user' => $user->id,
            'game' => $game->id,
        },
    );

    # Is the user active in the game?
    if (not defined $usergame or 0 == $usergame->active) {
        # No.
        $self->_irc->msg($chan, "$who: You're not playing!");
        return;
    }

    # Are they the Card Tsar? If so then they can't resign!
    if (1 == $usergame->is_tsar) {
        $self->_irc->msg($chan, "$who: You're the Card Tsar, you can't resign!");
        $self->_irc->msg($chan,
            "$who: Just pick a winner for this round first, then you can"
           . " resign.");
        return;
    }

    # Mark them as inactive.
    $usergame->active(0);
    $usergame->update;

    $self->_irc->msg($chan, "$who: Okay, you've been dealt out of the game.");
    $self->_irc->msg($chan,
        "$who: If you want to join in again later then type \"$my_nick: deal"
       . " me in\"");

   # Has this taken the number of players too low for the game to continue?
   my $player_count = scalar $game->rel_active_usergames;

   if ($player_count < 4) {
       $game->status(1);
       $game->update;

       $self->_irc->msg($chan,
           "That's taken us down to $player_count player"
          . (1 == $player_count ? '' : 's') . ". Game paused until we get back"
          . " up to 4.");
      $self->_irc->msg($chan,
          "Would anyone else would like to play? If so type \"$my_nick: me\"");
   }

   # TODO: all the card handling.
}

# Someone is asking for their current hand (of White Cards) to be displayed.
#
# First assume that they are only in one game so the channel will be implicit.
# If this proves to not be the case then ask them to try again with the channel
# specified.
sub do_priv_hand {
    my ($self, $args) = @_;

    my $who     = $args->{nick};
    my $user    = $self->db_get_user($who);
    my $my_nick = $self->_irc->nick();

    # This will be undef if a channel was not specified.
    my $chan = $args->{chan};

    # Only players active in at least one game will have a hand at all, so
    # check that first.
    my @active_usergames = $user->rel_active_usergames;

    # Did they specify a channel? If so then discard any active games that are
    # not for that channel.
    if (defined $chan) {
        @active_usergames = grep {
            $_->rel_game->rel_channel->name eq $chan
        } @active_usergames;
    }

    my $game_count = scalar @active_usergames;

    if (1 == $game_count) {
        my $ug    = $active_usergames[0];
        my @cards = $ug->rel_usergamehands;

        # Sort them by "wcardidx".
        @cards = sort { $a->wcardidx <=> $b->wcardidx } @cards;

        $self->_irc->msg($who,
            "Your White Cards in " . $ug->rel_game->rel_channel->disp_name
            . ":");
        $self->notify_wcards($ug, \@cards);
    } elsif (0 == $game_count) {
        if (defined $chan) {
            $self->_irc->msg($who,
                "Sorry, you don't appear to be active in a game in $chan yet.");
        } else {
            $self->_irc->msg($who,
                "Sorry, you don't appear to be active in any games yet.");
        }

        $self->_irc->msg($who,
            "If you'd like to start one then type \"$my_nick: start\" in the"
           . " channel you'd like to play in.");
        $self->_irc->msg($who,
            "Or you can join a running game with \"$my_nick: deal me in\".");
    } else {
        # Can only get here if they did not specify a channel. If they *had*
        # specified a channel then there would only have been one item in
        # @active_usergames. So we need to ask them to specify.
        my @channels = map {
            $_->rel_game->rel_channel->name
        } @active_usergames;

        my $last            = pop @channels;
        my $channels_string = join(', ', @channels) . ", and $last";

        $self->_irc->msg($who,
            "Sorry, you appear to be active in games in $channels_string.");
        $self->_irc->msg($who,
            "You're going to have to be more specific! Type \"$last hand\" for"
           . " example.");
    }

}

# Get the user row from the database that corresponds to the user nick as
# a string.
#
# If there is no such user in the database then create it and return that.
#
# Arguments:
#
# - user nick
#
# Returns:
#
# PAH::Schema::Result::User object
sub db_get_user {
    my ($self, $nick) = @_;

    my $schema = $self->_schema;

    return $schema->resultset('User')->find_or_create(
        { 'nick' => $nick },
    );
}


# Get the channel row from the database that corresponds to the channel name as
# a string.
#
# Arguments:
#
# - channel name
#
# Returns:
#
# PAH::Schema::Result::Channel object, or undef.
sub db_get_channel {
    my ($self, $chan) = @_;

    my $schema = $self->_schema;

    return $schema->resultset('Channel')->find(
        { 'name' => $chan },
    );
}

# Create a Black Card deck and a White Card deck in the database, unique to a
# specific game, referencing indices into our arrays of cards.
#
# The indices of the cards will be inserted in random order. Therefore we can
# iterate through a random deck by selecting increasing row ID numbers.
#
# Our template decks are:
#  $self->_deck->{deckname}->{Black}
#  $self->_deck->{deckname}->{White}
#
# Arguments:
#
# - Game Schema object
#
# Returns:
#
# Nothing.
sub db_populate_cards {
    my ($self, $game) = @_;

    my $schema   = $self->_schema;
    my $deckname = $game->deck;
    my $deck     = $self->_deck->{$deckname};

    my @bcard_indices = shuffle (0 .. (scalar @{ $deck->{Black} } - 1));
    my @wcard_indices = shuffle (0 .. (scalar @{ $deck->{White} } - 1));

    my @bcards = map { { game => $game->id, cardidx => $_ } } @bcard_indices;
    my @wcards = map { { game => $game->id, cardidx => $_ } } @wcard_indices;

    $schema->resultset('BCard')->populate(\@bcards);
    $schema->resultset('WCard')->populate(\@wcards);
}

# A game has just started so give a brief private introduction to each player.
#
# Arguments:
#
# - Game Schema object
#
# Returns:
#
# Nothing.
sub brief_players {
    my ($self, $game) = @_;

    my $chan    = $game->rel_channel->disp_name;
    my $my_nick = $self->_irc->nick();

    my @active_usergames = $game->rel_active_usergames;

    foreach my $ug (@active_usergames) {
        my $who = $ug->rel_user->nick;

        $self->_irc->msg($who,
            "Hi! The game's about to start. You may find it easier to keep this"
           . " window open for sending me game commands.");
        $self->_irc->msg($who,
            "Turns in this game can take up to 48 hours, so there's no need to"
           . " rush.");
        $self->_irc->msg($who,
            "If you need to stop playing though, please type"
           . " \"$my_nick: resign\" in $chan so the others aren't kept"
           . " waiting.");
    }
}

# A round has just started so each player will need their hand topping back up
# to 10 White Cards.
#
# Arguments:
#
# - Game Schema object
#
# Returns:
#
# Nothing.
sub topup_hands {
    my ($self, $game) = @_;

    my $schema  = $self->_schema;
    my $channel = $game->rel_channel;

    my @active_usergames = $game->rel_active_usergames;

    foreach my $ug (@active_usergames) {
        my $user       = $ug->rel_user;
        my $num_wcards = scalar $ug->rel_usergamehands;

        debug("%s currently has %u White Cards in %s game",
            $user->nick, $num_wcards, $channel->disp_name);

        my $needed = 10 - $num_wcards;

        $needed = 0  if ($needed < 0);
        $needed = 10 if ($needed > 10);

        debug("Dealing %u White Cards off the top for %s",
            $needed, $user->nick);

        # Grab the top $needed cards off this game's White deck…
        my @new = $schema->resultset('WCard')->search(
            {
                game => $game->id,
            },
            {
                order_by => { '-asc' => 'id' },
                rows     => $needed,
            },
        );

        # Construct an array of hashrefs representing the insert into the hand…
        my @to_insert = map {
            { user_game => $ug->id, wcardidx => $_->cardidx }
        } @new;

        # Actually do the insert…
        $schema->resultset('UserGameHand')->populate(\@to_insert);

        my @to_delete = map { $_->id } @new;

        # Now delete those cards from the White deck (because they now reside
        # in the user's hand.
        $schema->resultset('WCard')->search(
            {
                game => $game->id,
                id   => { '-in' => \@to_delete },
            }
        )->delete;

        # Sort them by "cardidx".
        @new = sort { $a->cardidx <=> $b->cardidx } @new;

        $self->notify_new_wcards($ug, \@new);
    }
}

# Tell a user about the fact that some White Cards just got added to their hand.
#
# Arguments
#
# - The UserGame Schema object for this User/Game.
# - An arrayref of WCard Schema objects representing the new cards.
#
# Returns:
#
# Nothing.
sub notify_new_wcards {
    my ($self, $ug, $new) = @_;

    my $who  = $ug->rel_user->nick;
    my $deck = $self->_deck->{$ug->rel_game->deck};

    my $num_added = scalar @{ $new };

    $self->_irc->msg($who,
        "$num_added new White Card" . (1 == $num_added ? '' :  's')
        . " have been dealt to you:");

    $self->notify_wcards($ug, $new);

    if ($num_added < 10) {
        $self->_irc->msg($who, "To see your full hand, say \"hand\".");
    }
}

# List off a set of White Cards to a user.
#
# Arguments:
#
# - The UserGame Schema object for this User/Game.
# - An arrayref of Schema objects representing the cards. This can be either
#   ::WCard or ::UserGameHand, which represent either a White Card in the deck
#   or a White Card in the hand, respectively.
#
#   If the object is a ::WCard then the accessor for the card index will be
#   "cardidx", otherwise it will be "wcardidx".
#
# Returns:
#
# Nothing.
sub notify_wcards {
    my ($self, $ug, $cards) = @_;

    my $who  = $ug->rel_user->nick;
    my $deck = $self->_deck->{$ug->rel_game->deck};

    my $i = 0;

    foreach my $wcard (@{ $cards }) {
        $i++;

        my $index;

        if ($wcard->has_column('wcardidx')) {
            # This is a ::UserGameHand.
            $index = $wcard->wcardidx;
        } else {
            # This is a ::WCard.
            $index = $wcard->cardidx;
        }

        my $text = $deck->{White}->[$index];

        # Upcase the first character and add a period on the end unless it
        # already has some punctuation.
        $text = ucfirst($text);

        if ($text !~ /[\.\?\!]$/) {
            $text .= '.';
        }

        $self->_irc->msg($who, sprintf("%2u. %s", $i, $text));
    }
}

# Deal a new Black Card to the Card Tsar and tell the channel about it. This
# marks the start of a new hand.
#
# Arguments:
#
# - The Game Schema object for this game.
#
# Returns:
#
# Nothing.
sub deal_to_tsar {
    my ($self, $game) = @_;

    my $schema    = $self->_schema;
    my $chan      = $game->rel_channel->disp_name;
    my @usergames = $game->rel_active_usergames;

    # First match only.
    my ($tsar) = grep { 1 == $_->is_tsar } @usergames;

    # Grab the top Black Card off this game's deck…
    my $new = $schema->resultset('BCard')->find(
        {
            game => $game->id,
        },
        {
            order_by => { '-asc' => 'id' },
            rows     => 1,
        },
    );

    # Update the Game with the index of the current black card.
    $game->bcardidx($new->cardidx);
    $game->activity_time(time());
    $game->update;

    # Discard the Black Card off the deck (because it's now part of the Game round).
    $schema->resultset('BCard')->find({ id => $new->id })->delete;

    # Notify the channel about the new Black Card.
    $self->_irc->msg($chan, "Time for the next Black Card:");
    $self->notify_bcard($chan, $game);
    $self->_irc->msg($chan, "Now message me your answers please!");
}

# Tell a channel or nick about the Black Card that has just been dealt.
#
# Arguments:
#
# - The target of the message (channel name or nickname).
# - The Game Schema object for this game.
#
# Returns:
#
# Nothing.
sub notify_bcard {
    my ($self, $who, $game) = @_;

    my $channel = $game->rel_channel;
    my $chan    = $channel->disp_name;
    my $deck    = $self->_deck->{$game->deck};
    my $text    = $deck->{Black}->[$game->bcardidx];

    foreach my $line (split(/\n/, $text)) {
        # Sometimes YAML leaves us with a trailing newline in the text.
        next if ($line =~ /^\s*$/);

        $self->_irc->msg($who, "→ $line");
    }

}

# Tell a user the text of the current black card.
#
# A complication here is that this command can be called by anyone, so they may
# not be an active player or even be a player at all.
#
# If they are an active player in just one game then we know what channel this
# relates to, but if no channel is specified and they're not active or are
# active in multiple then we'll need to ask them to specify.
sub do_priv_black {
    my ($self, $args) = @_;

    my $irc     = $self->_irc;
    my $schema  = $self->_schema;
    my $who     = $args->{nick};
    my $user    = $self->db_get_user($who);
    my $my_nick = $self->_irc->nick();

    # This will be undef if a channel was not specified.
    my $chan = $args->{chan};

    my $game;

    # Try to work out which Game we should be operating on here.
    if (defined $chan) {
        # They specified a channel. Is there a game for that channel?
        my $channel = $schema->resultset('Channel')->find(
            {
                name => $chan,
            }
        );

        if (not defined $channel) {
            # Can't be a game there, then.
            $irc->msg($who, sprintf("There's no game running in %s!", $chan));
            return;
        }

        $game = $channel->rel_game;
    } else {
        my @active_usergames = $user->rel_active_usergames;

        my $game_count = scalar @active_usergames;

        if (1 == $game_count) {
            # Simplest case: they are an active player in one game.
            $game = $active_usergames[0]->rel_game;
            $chan = $game->rel_channel->disp_name;
        } elsif (0 == $game_count) {
            # They aren't active in any game, and they didn't specify a
            # channel, so no way to know which channel they meant.
            $irc->msg($who,
                "Sorry, you're going to have to tell me which channel's game you're"
               . " interested in.");
            $irc->msg($who, "Try again with \"/msg $my_nick #channel black\"");
            return;
        } else {
            # They're in more than one game so again no way to tell which one
            # they mean.
            $irc->msg($who,
                "Sorry, you appear to be in multiple games so you're going to have"
               . " to specify which one you mean.");
            $irc->msg($who, "Try again with \"/msg $my_nick #channel black\"");
            return;
        }
    }

    if (not defined $game) {
        # Shouldn't be possible to get here without a Game.
        debug("Somehow ended up without a valid Game object");
        return;
    }

    if ($game->status != 2) {
        # There is a game but it's not running.
        $irc->msg($who, "The game in $chan is currently paused.");
        return;
    }

    $irc->msg($who, "Current Black Card for game in $chan:");
    $self->notify_bcard($who, $game);

    my @active_usergames = $game->rel_active_usergames;
    my ($usergame) = grep { $_->rel_user->id == $user->id } @active_usergames;
    my ($tsar)     = grep { 1 == $_->is_tsar } @active_usergames;

    if ($tsar->rel_user->nick eq $who) {
        # They're the Card Tsar.
        $irc->msg($who, "You're the current Card Tsar!");
    } else {
        $self->_irc->msg($who,
            sprintf("The current Card Tsar is %s", $tsar->rel_user->nick));

        # Are they in a position to play a move?
        if (defined $usergame) {
            $irc->msg($who, "Use the \"Play\" command to make your play!");
        }
    }

}

# A user wants to make a play from their hand of White Cards. After sanity
# checks we'll take the play and then repeat it back to them so they can
# appreciate the full impact of their choice.
#
# They can make another play at any time up until when the Card Tsar views the
# cards.
sub do_priv_play {
    my ($self, $args) = @_;

    my $who     = $args->{nick};
    my $params  = $args->{params};
    my $user    = $self->db_get_user($who);
    my $irc     = $self->_irc;
    my $my_nick = $irc->nick();

    # This will be undef if a channel was not specified.
    my $chan = $args->{chan};

    # Only players active in at least one game will have a hand at all, so
    # check that first.
    my @active_usergames = $user->rel_active_usergames;

    # Did they specify a channel? If so then discard any active games that are
    # not for that channel.
    if (defined $chan) {
        @active_usergames = grep {
            $_->rel_game->rel_channel->name eq $chan
        } @active_usergames;
    }

    my $game_count = scalar @active_usergames;

    if (0 == $game_count) {
        $irc->msg($who, "You aren't currently playing a game with me!");
        $irc->msg($who,
            sprintf("You probably want to be typing \"%s: start\" "
                    . "or \"%s: deal me in\" in a channel."), $my_nick, $my_nick);
        return;
    } elsif ($game_count > 1) {
        # Can only get here when the channel is not specified.
        # Since they're in multiple active games we need to ask them to specify
        # which game they intend to make a play for.
        $irc->msg($who,
            "Sorry, you're in multiple active games right now so I need you to"
           . " specify which channel you mean.");
        $irc->msg($who,
            "You can do that by typing \"/msg $my_nick #channel play …\"");
        return;
    }

    # Finally we've got the specific UserGame for this player and channel.
    my $ug        = $active_usergames[0];
    my $game      = $ug->rel_game;
    my $channel   = $game->rel_channel;
    my $num_plays = $self->num_plays($game);

    # Is there already a full set of plays for this game? If so then no more
    # changes are allowed.
    my $num_players = scalar $game->rel_active_usergames;

    if ($num_plays == ($num_players - 1)) {
        $irc->msg($who,
            sprintf("All plays have already been made for this game, so no changes"
               . " now! We're now waiting on the Card Tsar (%s).",
               $game->rel_tsar_usergame->rel_user->nick));
        return;
    }

    # Are they the Card Tsar? The Tsar doesn't get to play!
    if (1 == $ug->is_tsar) {
        $irc->msg($who,
            sprintf("You're currently the Card Tsar for %s; you don't get to play"
               . " any White Cards yet!", $channel->disp_name));
       return;
    }

    # Does their play even make sense?
    my ($first, $second);

    my $bcardidx     = $game->bcardidx;
    my $cards_needed = $self->how_many_blanks($game, $bcardidx);

    if (not defined $params or 0 == length($params)) {
        if (1 == $cards_needed) {
            $irc->msg($who,
                qq{I need one answer and you've given me none! Try}
               . qq{ "/msg $my_nick play 1" where "1" is the White Card}
               . qq{ number from your hand.});
        } else {
            $irc->msg($who,
                qq{I need two answers and you've given me none! Try}
               . qq{ "/msg $my_nick play 1 2" where "1" and "2" are the White Card}
               . qq{ numbers from your hand.});
        }
        return;
    }

    if (1 == $cards_needed) {
        if ($params =~ /^\s*(\d+)\s*$/ and $1 > 0) {
            $first = $1;
        } else {
            $irc->msg($who, "Sorry, this Black Card needs one White Card and"
               . " \"$params\" doesn't look like a single, positive integer. Try"
               . " again!");
            return;
        }
    } elsif (2 == $cards_needed) {
        if ($params =~ /^\s*(\d+)\s*(?:\s+|,|\&)\s*(\d+)\s*$/
                and $1 > 0 and $2 > 0) {
            $first  = $1;
            $second = $2;
        } else {
            $irc->msg($who,
                "Sorry, this Black Card needs two White Cards. Do it like this:");
            $irc->msg($who, qq{/msg $my_nick play 1 2});
            return;
        }
    } else {
        debug("Black Card with index %u appears to need %u answers, which is weird.",
            $bcardidx, $cards_needed);
        return;
    }

    $irc->msg($who, "Thanks. So this is your play:");

    my $play;
    my $cards;

    if (1 == $cards_needed) {
        my $first_ugh = $self->db_get_nth_wcard($ug, $first);

        $cards = [ $first_ugh ];
    } else {
        my $first_ugh  = $self->db_get_nth_wcard($ug, $first);
        my $second_ugh = $self->db_get_nth_wcard($ug, $second);

        $cards = [ $first_ugh, $second_ugh ];
    }

    $play = $self->build_play($ug, $bcardidx, $cards);

    foreach my $line (split(/\n/, $play)) {
        # Sometimes YAML leaves us with a trailing newline in the text.
        next if ($line =~ /^\s*$/);

        $irc->msg($who, "→ $line");
    }

    # Record the play in this game's tally.
    my $is_new = 1;

    if (defined $self->_plays and defined $self->_plays->{$game->id}
            and defined $self->_plays->{$game->id}->{$user->id}) {
        $is_new = 0;
    }

    $self->_plays->{$game->id}->{$user->id} = {
        cards => $cards,
        play  => $play,
    };

    $num_plays++;

    # Tell the channel that the user has made their play.
    if ($num_plays == ($num_players - 1)) {
        $irc->msg($channel->name, "All plays are in. No more changes!");

        # Assign random sequence order to the plays just in case Perl's
        # ordering of hash keys is predictable.
        my @sequence = shuffle (1 .. ($num_players - 1));
        my $i = 0;

        foreach my $uid (keys %{ $self->_plays->{$game->id} }) {
            $self->_plays->{$game->id}->{$uid}->{seq} = $sequence[$i];
            $i++;
        }

        # Tell the channel about the collection of plays.
        $self->list_plays($game);

        # TODO: poke Card Tsar into action.
    } elsif ($is_new) {
        my $waiting_on = $num_players - $num_plays - 1;
        # Only bother to tell the channel if this is a new play.
        # User can then keep changing their play without spamming the channel.
        $irc->msg($channel->name,
            sprintf("%s has made their play! We're waiting on %u more play%s.",
                $who, $waiting_on, $waiting_on == 1 ? '' : 's'));
    }
}

# Assemble a play from the current Black Card and some White Cards.
#
# Arguments:
#
# - The UserGame Schema object.
#
# - A scalar representing the index into the Black Card deck for the current
#   Black Card.
#
# - An arrayref of the UserGameHands for the White Cards played, in order.
#   There should be either one or two of them.
#
# Returns:
#
# - The formatted play.
sub build_play {
    my ($self, $ug, $bcardidx, $ughs) = @_;

    my $game     = $ug->rel_game;
    my $deckname = $game->deck;
    my $deck     = $self->_deck->{$deckname};
    my $btext    = $deck->{Black}->[$bcardidx];

    if ($btext !~ /_{5,}/s) {
        # There's no blanks in this Black Card text so this will be a 1-card
        # answer, tacked on the end.
        $btext = sprintf("%s %s.",
            $btext, ucfirst($deck->{White}->[$ughs->[0]->wcardidx]));
        return $btext;
    }

    my $ugh   = shift @{ $ughs };
    my $wtext = $deck->{White}->[$ugh->wcardidx];

    $btext =~ s/_{5,}/$wtext/s;

    # If there's still a UserGameHand left, do it again.
    if (scalar @{ $ughs }) {
        $ugh   = shift @{ $ughs };
        $wtext = $deck->{White}->[$ugh->wcardidx];

        $btext =~ s/_{5,}/$wtext/s;
    }

    # Upper-case things we put at the start.
    $btext =~ s/^(\S)/uc($1)/e;

    # Upper-case things we put after ".!?".
    $btext =~ s/([\.\?\!] \S)/uc($1)/gse;

    return $btext;
}

# Return the UserGameHand row corresponding to the n'th card for a given
# UserGame, ordered by wcardix.
#
# Arguments:
#
# - The UserGame Schema object.
# - The index (1-based, so "2" would be the second card).
#
# Returns:
#
# A UserGameHand Schema object or undef.
sub db_get_nth_wcard {
    my ($self, $ug, $idx) = @_;

    my $schema = $self->_schema;

    return $schema->resultset('UserGameHand')->find(
        {
            user_game => $ug->id,
        },
        {
            order_by => { '-asc' => 'wcardidx' },
            rows     => 1,
            offset   => $idx - 1,
        },
    );
}

# Work out how many blanks (spaces for an answer) a particular Black Card has.
#
# A blank is defined as 5 or more underscores in a row.
#
# A Black Card with no such sequences of underscores has one implicit blank, at
# the end.
#
# Other possible numbers are 1 and 2.
#
# Arguments:
#
# - The Game Schema object.
#
# - A scalar representing the index into the Black Card deck for the current
#   Black Card.
#
# Returns:
#
# - How many blanks.
sub how_many_blanks {
    my ($self, $game, $idx) = @_;

    my $deckname = $game->deck;
    my $deck     = $self->_deck->{$deckname};
    my $text     = $deck->{Black}->[$idx];

    if ($text !~ /_____/s) {
        # no blanks at all, so that's 1.
        return 1;
    }

    my @count = $text =~ m/_{5,}/gs;

    return scalar @count;
}

# Return the number of plays that have been made in this game so far.
#
# Arguments:
#
# - The Game Schema object.
#
# Returns:
#
# - The number of plays made so far.
sub num_plays {
    my ($self, $game) = @_;

    if (defined $self->_plays and defined $self->_plays->{$game->id}) {
        return scalar keys %{ $self->_plays->{$game->id} };
    } else {
        return 0;
    }
}

# Inform the channel about the (completed) set of plays.
#
# Arguments:
#
# - The Game Schema object.
#
# Returns:
#
# Nothing.
sub list_plays {
    my ($self, $game) = @_;

    my $irc     = $self->_irc;
    my $channel = $game->rel_channel;

    # Hash ref of User ids.
    my $plays = $self->_plays->{$game->id};

    # Go through the plays in the specified sequence order just in case Perl's
    # hash ordering is predictable.
    foreach my $uid (
        sort { $plays->{$a}->{seq} <=> $plays->{$b}->{seq} }
        keys %{ $plays }) {

        my $seq  = $plays->{$uid}->{seq};
        my $text = $plays->{$uid}->{play};

        if (1 == $seq) {
            $irc->msg($channel->name,
                sprintf("%s: Which is the best play?",
                    $game->rel_tsar_usergame->rel_user->nick));
        } else {
            $irc->msg($channel->name, "…or…");
        }

        foreach my $line (split(/\n/, $text)) {
            # Sometimes YAML leaves us with a trailing newline in the text.
            next if ($line =~ /^\s*$/);

            $irc->msg($channel->name, "$seq → $line");
        }
    }
}

1;