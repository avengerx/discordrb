require 'rest-client'
require 'faye/websocket'
require 'eventmachine'

require 'discordrb/events/message'
require 'discordrb/events/typing'
require 'discordrb/events/lifetime'
require 'discordrb/events/presence'
require 'discordrb/events/voice_state_update'
require 'discordrb/events/channel_create'
require 'discordrb/events/channel_update'
require 'discordrb/events/channel_delete'
require 'discordrb/events/members'
require 'discordrb/events/guild_role_create'
require 'discordrb/events/guild_role_delete'
require 'discordrb/events/guild_role_update'
require 'discordrb/events/guilds'
require 'discordrb/events/await'
require 'discordrb/events/bans'

require 'discordrb/api'
require 'discordrb/errors'
require 'discordrb/data'
require 'discordrb/await'
require 'discordrb/token_cache'
require 'discordrb/container'

require 'discordrb/voice/voice_bot'

module Discordrb
  # Represents a Discord bot, including servers, users, etc.
  class Bot
    # The user that represents the bot itself. This version will always be identical to
    # the user determined by {#user} called with the bot's ID.
    # @return [User] The bot user.
    attr_reader :bot_user

    # The list of users the bot shares a server with.
    # @return [Array<User>] The users.
    attr_reader :users

    # The list of servers the bot is currently in.
    # @return [Array<Server>] The servers.
    attr_reader :servers

    # The list of currently running threads used to parse and call events.
    # The threads will have a local variable `:discordrb_name` in the format of `et-1234`, where
    # "et" stands for "event thread" and the number is a continually incrementing number representing
    # how many events were executed before.
    # @return [Array<Thread>] The threads.
    attr_reader :event_threads

    # The bot's user profile. This special user object can be used
    # to edit user data like the current username (see {Profile#username=}).
    # @return [Profile] The bot's profile that can be used to edit data.
    attr_reader :profile

    # Whether or not the bot should parse its own messages. Off by default.
    attr_accessor :should_parse_self

    # The bot's name which discordrb sends to Discord when making any request, so Discord can identify bots with the
    # same codebase. Not required but I recommend setting it anyway.
    attr_accessor :name

    include EventContainer

    # Makes a new bot with the given email and password. It will be ready to be added event handlers to and can eventually be run with {#run}.
    # @param email [String] The email for your (or the bot's) Discord account.
    # @param password [String] The valid password that should be used to log in to the account.
    # @param debug [Boolean] Whether or not the bug should run in debug mode, which gives increased console output.
    def initialize(email, password, debug = false)
      # Make sure people replace the login details in the example files...
      if email.is_a?(String) && email.end_with?('example.com')
        puts 'You have to replace the login details in the example files with your own!'
        exit
      end

      LOGGER.debug = debug
      @should_parse_self = false

      @email = email
      @password = password

      @name = ''

      debug('Creating token cache')
      @token_cache = Discordrb::TokenCache.new
      debug('Token cache created successfully')
      @token = login

      @channels = {}
      @users = {}

      # Channels the bot has no permission to, for internal tracking
      @restricted_channels = []

      @event_threads = []
      @current_thread = 0
    end

    # The Discord API token received when logging in. Useful to explicitly call
    # {API} methods.
    # @return [String] The API token.
    def token
      API.bot_name = @name
      @token
    end

    # Runs the bot, which logs into Discord and connects the WebSocket. This prevents all further execution unless it is executed with `async` = `:async`.
    # @param async [Symbol] If it is `:async`, then the bot will allow further execution.
    #   It doesn't necessarily have to be that, anything truthy will work,
    #   however it is recommended to use `:async` for code readability reasons.
    #   If the bot is run in async mode, make sure to eventually run {#sync} so
    #   the script doesn't stop prematurely.
    def run(async = false)
      run_async
      return if async

      debug('Oh wait! Not exiting yet as run was run synchronously.')
      sync
    end

    # Runs the bot asynchronously. Equivalent to #run with the :async parameter.
    # @see #run
    def run_async
      # Handle heartbeats
      @heartbeat_interval = 1
      @heartbeat_active = false
      @heartbeat_thread = Thread.new do
        Thread.current[:discordrb_name] = 'heartbeat'
        loop do
          sleep @heartbeat_interval
          send_heartbeat if @heartbeat_active
        end
      end

      @ws_thread = Thread.new do
        Thread.current[:discordrb_name] = 'websocket'

        # Initialize falloff so we wait for more time before reconnecting each time
        @falloff = 1.0

        loop do
          websocket_connect
          debug("Disconnected! Attempting to reconnect in #{@falloff} seconds.")
          sleep @falloff
          @token = login

          # Calculate new falloff
          @falloff *= 1.5
          @falloff = 115 + (rand * 10) if @falloff > 1 # Cap the falloff at 120 seconds and then add some random jitter
        end
      end

      debug('WS thread created! Now waiting for confirmation that everything worked')
      @ws_success = false
      sleep(0.5) until @ws_success
      debug('Confirmation received! Exiting run.')
    end

    # Prevents all further execution until the websocket thread stops (e. g. through a closed connection).
    def sync
      @ws_thread.join
    end

    # Kills the websocket thread, stopping all connections to Discord.
    def stop
      @ws_thread.kill
    end

    # Gets a channel given its ID. This queries the internal channel cache, and if the channel doesn't
    # exist in there, it will get the data from Discord.
    # @param id [Integer] The channel ID for which to search for.
    # @return [Channel] The channel identified by the ID.
    def channel(id)
      id = id.resolve_id

      raise Discordrb::Errors::NoPermission if @restricted_channels.include? id

      debug("Obtaining data for channel with id #{id}")
      return @channels[id] if @channels[id]

      begin
        response = API.channel(token, id)
        channel = Channel.new(JSON.parse(response), self)
        @channels[id] = channel
      rescue Discordrb::Errors::NoPermission
        debug "Tried to get access to restricted channel #{id}, blacklisting it"
        @restricted_channels << id
        raise
      end
    end

    # Creates a private channel for the given user ID, or if one exists already, returns that one.
    # It is recommended that you use {User#pm} instead, as this is mainly for internal use. However,
    # usage of this method may be unavoidable if only the user ID is known.
    # @param id [Integer] The user ID to generate a private channel for.
    # @return [Channel] A private channel for that user.
    def private_channel(id)
      id = id.resolve_id
      debug("Creating private channel with user id #{id}")
      return @private_channels[id] if @private_channels[id]

      response = API.create_private(token, @bot_user.id, id)
      channel = Channel.new(JSON.parse(response), self)
      @private_channels[id] = channel
    end

    # Gets the code for an invite.
    # @param invite [String, Invite] The invite to get the code for. Possible formats are:
    #
    #    * An {Invite} object
    #    * The code for an invite
    #    * A fully qualified invite URL (e. g. `https://discordapp.com/invite/0A37aN7fasF7n83q`)
    #    * A short invite URL with protocol (e. g. `https://discord.gg/0A37aN7fasF7n83q`)
    #    * A short invite URL without protocol (e. g. `discord.gg/0A37aN7fasF7n83q`)
    # @return [String] Only the code for the invite.
    def resolve_invite_code(invite)
      invite = invite.code if invite.is_a? Discordrb::Invite
      invite = invite[invite.rindex('/') + 1..-1] if invite.start_with?('http', 'discord.gg')
      invite
    end

    # Gets information about an invite.
    # @param invite [String, Invite] The invite to join. For possible formats see {#resolve_invite_code}.
    # @return [Invite] The invite with information about the given invite URL.
    def invite(invite)
      code = resolve_invite_code(invite)
      Invite.new(JSON.parse(API.resolve_invite(token, code)), self)
    end

    # Makes the bot join an invite to a server.
    # @param invite [String, Invite] The invite to join. For possible formats see {#resolve_invite_code}.
    def join(invite)
      resolved = invite(invite).code
      API.join_server(token, resolved)
    end

    attr_reader :voice

    # Connects to a voice channel, initializes network connections and returns the {Voice::VoiceBot} over which audio
    # data can then be sent. After connecting, the bot can also be accessed using {#voice}.
    # @param chan [Channel] The voice channel to connect to.
    # @param encrypted [true, false] Whether voice communication should be encrypted using RbNaCl's SecretBox
    #   (uses an XSalsa20 stream cipher for encryption and Poly1305 for authentication)
    # @return [Voice::VoiceBot] the initialized bot over which audio data can then be sent.
    def voice_connect(chan, encrypted = true)
      if @voice
        debug('Voice bot exists already! Destroying it')
        @voice.destroy
        @voice = nil
      end

      chan = channel(chan.resolve_id)
      @voice_channel = chan
      @should_encrypt_voice = encrypted

      debug("Got voice channel: #{@voice_channel}")

      data = {
        op: 4,
        d: {
          guild_id: @voice_channel.server.id.to_s,
          channel_id: @voice_channel.id.to_s,
          self_mute: false,
          self_deaf: false
        }
      }
      debug("Voice channel init packet is: #{data.to_json}")

      @should_connect_to_voice = true
      @ws.send(data.to_json)
      debug('Voice channel init packet sent! Now waiting.')

      sleep(0.05) until @voice
      debug('Voice connect succeeded!')
      @voice
    end

    # Disconnects the client from all voice connections across Discord.
    # @param destroy_vws [true, false] Whether or not the VWS should also be destroyed. If you're calling this method
    #   directly, you should leave it as true.
    def voice_destroy(destroy_vws = true)
      data = {
        op: 4,
        d: {
          guild_id: nil,
          channel_id: nil,
          self_mute: false,
          self_deaf: false
        }
      }

      debug("Voice channel destroy packet is: #{data.to_json}")
      @ws.send(data.to_json)

      @voice.destroy if @voice && destroy_vws
      @voice = nil
    end

    # Revokes an invite to a server. Will fail unless you have the *Manage Server* permission.
    # It is recommended that you use {Invite#delete} instead.
    # @param code [String, Invite] The invite to revoke. For possible formats see {#resolve_invite_code}.
    def delete_invite(code)
      invite = resolve_invite_code(code)
      API.delete_invite(token, invite)
    end

    # Gets a user by its ID.
    # @note This can only resolve users known by the bot (i.e. that share a server with the bot).
    # @param id [Integer] The user ID that should be resolved.
    # @return [User, nil] The user identified by the ID, or `nil` if it couldn't be found.
    def user(id)
      id = id.resolve_id
      @users[id]
    end

    # Gets a server by its ID.
    # @note This can only resolve servers the bot is currently in.
    # @param id [Integer] The server ID that should be resolved.
    # @return [Server, nil] The server identified by the ID, or `nil` if it couldn't be found.
    def server(id)
      id = id.resolve_id
      @servers[id]
    end

    # Finds a channel given its name and optionally the name of the server it is in.
    # @param channel_name [String] The channel to search for.
    # @param server_name [String] The server to search for, or `nil` if only the channel should be searched for.
    # @return [Array<Channel>] The array of channels that were found. May be empty if none were found.
    def find_channel(channel_name, server_name = nil)
      results = []

      @servers.values.each do |server|
        server.channels.each do |channel|
          results << channel if channel.name == channel_name && (server_name || server.name) == server.name
        end
      end

      results
    end

    # Finds a user given its username.
    # @param username [String] The username to look for.
    # @return [Array<User>] The array of users that were found. May be empty if none were found.
    def find_user(username)
      @users.values.find_all { |e| e.username == username }
    end

    # @deprecated Use {#find_channel} instead
    def find(channel_name, server_name = nil)
      debug('Attempted to use bot.find - this method is deprecated! Use find_channel for the same functionality')
      find_channel(channel_name, server_name)
    end

    # Sends a text message to a channel given its ID and the message's content.
    # @param channel_id [Integer] The ID that identifies the channel to send something to.
    # @param content [String] The text that should be sent as a message. It is limited to 2000 characters (Discord imposed).
    # @param tts [true, false] Whether or not this message should be sent using Discord text-to-speech.
    # @return [Message] The message that was sent.
    def send_message(channel_id, content, tts = false)
      debug("Sending message to #{channel_id} with content '#{content}'")

      response = API.send_message(token, channel_id, content, [], tts)
      Message.new(JSON.parse(response), self)
    end

    # Sends a file to a channel. If it is an image, it will automatically be embedded.
    # @note This executes in a blocking way, so if you're sending long files, be wary of delays.
    # @param channel_id [Integer] The ID that identifies the channel to send something to.
    # @param file [File] The file that should be sent.
    def send_file(channel_id, file)
      response = API.send_file(token, channel_id, file)
      Message.new(JSON.parse(response), self)
    end

    # Creates a server on Discord with a specified name and a region.
    # @note Discord's API doesn't directly return the server when creating it, so this method
    #   waits until the data has been received via the websocket. This may make the execution take a while.
    # @param name [String] The name the new server should have. Doesn't have to be alphanumeric.
    # @param region [Symbol] The region where the server should be created. Possible regions are:
    #
    #   * `:london`
    #   * `:amsterdam`
    #   * `:frankfurt`
    #   * `:us-east`
    #   * `:us-west`
    #   * `:us-south`
    #   * `:us-central`
    #   * `:singapore`
    #   * `:sydney`
    # @return [Server] The server that was created.
    def create_server(name, region = :london)
      response = API.create_server(token, name, region)
      id = JSON.parse(response)['id'].to_i
      sleep 0.1 until @servers[id]
      server = @servers[id]
      debug "Successfully created server #{server.id} with name #{server.name}"
      server
    end

    # Creates a new application to do OAuth authorization with. This allows you to use OAuth to authorize users using
    # Discord. For information how to use this, see this example: https://github.com/vishnevskiy/discord-oauth2-example
    # @param name [String] What your application should be called.
    # @param redirect_uris [Array<String>] URIs that Discord should redirect your users to after authorizing.
    # @return [Array(String, String)] your applications' client ID and client secret to be used in OAuth authorization.
    def create_oauth_application(name, redirect_uris)
      response = JSON.parse(API.create_oauth_application(@token, name, redirect_uris))
      [response['id'], response['secret']]
    end

    # Changes information about your OAuth application
    # @param name [String] What your application should be called.
    # @param redirect_uris [Array<String>] URIs that Discord should redirect your users to after authorizing.
    # @param description [String] A string that describes what your application does.
    # @param icon [String, nil] A data URI for your icon image (for example a base 64 encoded image), or nil if no icon
    #   should be set or changed.
    def update_oauth_application(name, redirect_uris, description = '', icon = nil)
      API.update_oauth_application(@token, name, redirect_uris, description, icon)
    end

    # Gets the user from a mention of the user.
    # @param mention [String] The mention, which should look like <@12314873129>.
    # @return [User] The user identified by the mention, or `nil` if none exists.
    def parse_mention(mention)
      # Mention format: <@id>
      return nil unless /<@(?<id>\d+)>?/ =~ mention
      user(id.to_i)
    end

    # Sets the currently playing game to the specified game.
    # @param name [String] The name of the game to be played.
    # @return [String] The game that is being played now.
    def game=(name)
      @game = name

      data = {
        op: 3,
        d: {
          idle_since: nil,
          game: name ? { name: name } : nil
        }
      }

      @ws.send(data.to_json)
      name
    end

    # Sets debug mode. If debug mode is on, many things will be outputted to STDOUT.
    def debug=(new_debug)
      LOGGER.debug = new_debug
    end

    # Sets the logging mode
    # @see Logger#mode=
    def mode=(new_mode)
      LOGGER.mode = new_mode
    end

    # Prevents the READY packet from being printed regardless of debug mode.
    def suppress_ready_debug
      @prevent_ready = true
    end

    # Add an await the bot should listen to. For information on awaits, see {Await}.
    # @param key [Symbol] The key that uniquely identifies the await for {AwaitEvent}s to listen to (see {#await}).
    # @param type [Class] The event class that should be listened for.
    # @param attributes [Hash] The attributes the event should check for. The block will only be executed if all attributes match.
    # @yield Is executed when the await is triggered.
    # @yieldparam event [Event] The event object that was triggered.
    # @return [Await] The await that was created.
    def add_await(key, type, attributes = {}, &block)
      raise "You can't await an AwaitEvent!" if type == Discordrb::Events::AwaitEvent
      await = Await.new(self, key, type, attributes, block)
      @awaits ||= {}
      @awaits[key] = await
    end

    # @see Logger#debug
    def debug(message)
      LOGGER.debug(message)
    end

    # @see Logger#log_exception
    def log_exception(e)
      LOGGER.log_exception(e)
    end

    private

    #######     ###     ######  ##     ## ########
    ##    ##   ## ##   ##    ## ##     ## ##
    ##        ##   ##  ##       ##     ## ##
    ##       ##     ## ##       ######### ######
    ##       ######### ##       ##     ## ##
    ##    ## ##     ## ##    ## ##     ## ##
    #######  ##     ##  ######  ##     ## ########

    def add_server(data)
      server = Server.new(data, self)
      @servers[server.id] = server

      # Initialize users
      server.members.each do |member|
        if @users[member.id]
          # If the user is already cached, just add the new roles
          @users[member.id].merge_roles(server, member.roles[server.id])
        else
          @users[member.id] = member
        end
      end

      server
    end

    ### ##    ## ######## ######## ########  ##    ##    ###    ##        ######
    ##  ###   ##    ##    ##       ##     ## ###   ##   ## ##   ##       ##    ##
    ##  ####  ##    ##    ##       ##     ## ####  ##  ##   ##  ##       ##
    ##  ## ## ##    ##    ######   ########  ## ## ## ##     ## ##        ######
    ##  ##  ####    ##    ##       ##   ##   ##  #### ######### ##             ##
    ##  ##   ###    ##    ##       ##    ##  ##   ### ##     ## ##       ##    ##
    ### ##    ##    ##    ######## ##     ## ##    ## ##     ## ########  ######

    # Internal handler for PRESENCE_UPDATE
    def update_presence(data)
      user_id = data['user']['id'].to_i
      server_id = data['guild_id'].to_i
      server = @servers[server_id]
      return unless server

      user = @users[user_id]
      unless user
        user = User.new(data['user'], self)
        @users[user_id] = user
      end

      status = data['status'].to_sym
      if status != :offline
        unless server.members.find { |u| u.id == user.id }
          server.members << user
        end
      end

      username = data['user']['username']
      if username
        debug "User changed username: #{user.username} #{username}"
        user.update_username(username)
      end

      user.status = status
      user.game = data['game'] ? data['game']['name'] : nil
      user
    end

    # Internal handler for VOICE_STATUS_UPDATE
    def update_voice_state(data)
      user_id = data['user_id'].to_i
      server_id = data['guild_id'].to_i
      server = @servers[server_id]
      return unless server

      user = @users[user_id]
      user.server_mute = data['mute']
      user.server_deaf = data['deaf']
      user.self_mute = data['self_mute']
      user.self_deaf = data['self_deaf']

      channel_id = data['channel_id']
      channel = nil
      channel = self.channel(channel_id.to_i) if channel_id
      user.move(channel)

      @session_id = data['session_id']
    end

    # Internal handler for VOICE_SERVER_UPDATE
    def update_voice_server(data)
      debug("Voice server update received! should connect: #{@should_connect_to_voice}")
      return unless @should_connect_to_voice
      @should_connect_to_voice = false
      debug('Updating voice server!')

      token = data['token']
      endpoint = data['endpoint']
      channel = @voice_channel

      debug('Got data, now creating the bot.')
      @voice = Discordrb::Voice::VoiceBot.new(channel, self, token, @session_id, endpoint, @should_encrypt_voice)
    end

    # Internal handler for CHANNEL_CREATE
    def create_channel(data)
      channel = Channel.new(data, self)
      server = channel.server
      server.channels << channel
      @channels[channel.id] = channel
    end

    # Internal handler for CHANNEL_UPDATE
    def update_channel(data)
      channel = Channel.new(data, self)
      old_channel = @channels[channel.id]
      return unless old_channel
      old_channel.update_from(channel)
    end

    # Internal handler for CHANNEL_DELETE
    def delete_channel(data)
      channel = Channel.new(data, self)
      server = channel.server
      @channels[channel.id] = nil
      server.channels.reject! { |c| c.id == channel.id }
    end

    # Internal handler for GUILD_MEMBER_ADD
    def add_guild_member(data)
      user = User.new(data['user'], self)
      server_id = data['guild_id'].to_i
      server = @servers[server_id]

      roles = []
      data['roles'].each do |element|
        role_id = element.to_i
        roles << server.roles.find { |r| r.id == role_id }
      end
      user.update_roles(server, roles)

      if @users[user.id]
        # If the user is already cached, just add the new roles
        @users[user.id].merge_roles(server, user.roles[server.id])
      else
        @users[user.id] = user
      end

      server.add_user(user)
    end

    # Internal handler for GUILD_MEMBER_UPDATE
    def update_guild_member(data)
      user_id = data['user']['id'].to_i
      user = @users[user_id]

      server_id = data['guild_id'].to_i
      server = @servers[server_id]

      roles = []
      data['roles'].each do |element|
        role_id = element.to_i
        roles << server.roles.find { |r| r.id == role_id }
      end
      user.update_roles(server, roles)
    end

    # Internal handler for GUILD_MEMBER_DELETE
    def delete_guild_member(data)
      user_id = data['user']['id'].to_i
      user = @users[user_id]

      server_id = data['guild_id'].to_i
      server = @servers[server_id]

      user.delete_roles(server_id)
      server.delete_user(user_id)
    end

    # Internal handler for GUILD_CREATE
    def create_guild(data)
      add_server(data)
    end

    # Internal handler for GUILD_UPDATE
    def update_guild(data)
      @servers[data['id'].to_i].update_data(data)
    end

    # Internal handler for GUILD_DELETE
    def delete_guild(data)
      id = data['id'].to_i

      @users.each do |_, user|
        user.delete_roles(id)
      end

      @servers.delete(id)
    end

    # Internal handler for GUILD_ROLE_UPDATE
    def update_guild_role(data)
      role_data = data['role']
      server_id = data['guild_id'].to_i
      server = @servers[server_id]
      new_role = Role.new(role_data, self, server)
      role_id = role_data['id'].to_i
      old_role = server.roles.find { |r| r.id == role_id }
      old_role.update_from(new_role)
    end

    # Internal handler for GUILD_ROLE_CREATE
    def create_guild_role(data)
      role_data = data['role']
      server_id = data['guild_id'].to_i
      server = @servers[server_id]
      new_role = Role.new(role_data, self, server)
      server.add_role(new_role)
    end

    # Internal handler for GUILD_ROLE_DELETE
    def delete_guild_role(data)
      role_id = data['role_id'].to_i
      server_id = data['guild_id'].to_i
      server = @servers[server_id]
      server.delete_role(role_id)
    end

    # Internal handler for MESSAGE_CREATE
    def create_message(data); end

    # Internal handler for TYPING_START
    def start_typing(data); end

    # Internal handler for MESSAGE_UPDATE
    def update_message(data); end

    # Internal handler for MESSAGE_DELETE
    def delete_message(data); end

    # Internal handler for GUILD_BAN_ADD
    def add_user_ban(data); end

    # Internal handler for GUILD_BAN_REMOVE
    def remove_user_ban(data); end

    ##        #######   ######   #### ##    ##
    ##       ##     ## ##    ##   ##  ###   ##
    ##       ##     ## ##         ##  ####  ##
    ##       ##     ## ##   ####  ##  ## ## ##
    ##       ##     ## ##    ##   ##  ##  ####
    ##       ##     ## ##    ##   ##  ##   ###
    ########  #######   ######   #### ##    ##

    def login
      if @email == :token
        debug('Logging in using static token')

        # The password is the token!
        return @password
      end

      debug('Logging in')
      login_attempts ||= 0

      # First, attempt to get the token from the cache
      token = @token_cache.token(@email, @password)
      if token
        debug('Token successfully obtained from cache!')
        return token
      end

      # Login
      login_response = API.login(@email, @password)
      raise Discordrb::Errors::HTTPStatusError, login_response.code if login_response.code >= 400

      # Parse response
      login_response_object = JSON.parse(login_response)
      raise Discordrb::Errors::InvalidAuthenticationError unless login_response_object['token']

      debug('Received token from Discord!')

      # Cache the token
      @token_cache.store_token(@email, @password, login_response_object['token'])

      login_response_object['token']
    rescue Exception => e
      response_code = login_response.nil? ? 0 : login_response.code ######## mackmm145
      if login_attempts < 100 && (e.inspect.include?('No such host is known.') || response_code == 523)
        debug("Login failed! Reattempting in 5 seconds. #{100 - login_attempts} attempts remaining.")
        debug("Error was: #{e.inspect}")
        sleep 5
        login_attempts += 1
        retry
      else
        debug("Login failed permanently after #{login_attempts + 1} attempts")

        # Apparently we get a 400 if the password or username is incorrect. In that case, tell the user
        debug("Are you sure you're using the correct username and password?") if e.class == RestClient::BadRequest
        log_exception(e)
        raise $ERROR_INFO
      end
    end

    def find_gateway
      # Get updated websocket_hub
      response = API.gateway(token)
      JSON.parse(response)['url']
    end

    ##      ##  ######     ######## ##     ## ######## ##    ## ########  ######
    ##  ##  ## ##    ##    ##       ##     ## ##       ###   ##    ##    ##    ##
    ##  ##  ## ##          ##       ##     ## ##       ####  ##    ##    ##
    ##  ##  ##  ######     ######   ##     ## ######   ## ## ##    ##     ######
    ##  ##  ##       ##    ##        ##   ##  ##       ##  ####    ##          ##
    ##  ##  ## ##    ##    ##         ## ##   ##       ##   ###    ##    ##    ##
    ####  ###   ######     ########    ###    ######## ##    ##    ##     ######

    def websocket_connect
      debug('Attempting to get gateway URL...')
      websocket_hub = find_gateway
      debug("Success! Gateway URL is #{websocket_hub}.")
      debug('Now running bot')

      EM.run do
        @ws = Faye::WebSocket::Client.new(websocket_hub)

        @ws.on(:open) { |event| websocket_open(event) }
        @ws.on(:message) { |event| websocket_message(event) }
        @ws.on(:error) { |event| debug(event.message) }
        @ws.on :close do |event|
          websocket_close(event)
          @ws = nil
        end
      end
    end

    def websocket_message(event)
      # Parse packet
      packet = JSON.parse(event.data)

      if @prevent_ready && packet['t'] == 'READY'
        debug('READY packet was received and suppressed')
      elsif @prevent_ready && packet['t'] == 'GUILD_MEMBERS_CHUNK'
        # Ignore chunks as they will be handled later anyway
      else
        LOGGER.in(event.data.to_s)
      end

      raise 'Invalid Packet' unless packet['op'] == 0 # TODO

      data = packet['d']
      type = packet['t'].intern
      case type
      when :READY
        # Activate the heartbeats
        @heartbeat_interval = data['heartbeat_interval'].to_f / 1000.0
        @heartbeat_active = true
        debug("Desired heartbeat_interval: #{@heartbeat_interval}")

        bot_user_id = data['user']['id'].to_i
        @profile = Profile.new(data['user'], self, @email, @password)

        # Initialize servers
        @servers = {}
        data['guilds'].each do |element|
          add_server(element)

          # Save the bot user
          @bot_user = @users[bot_user_id]
        end

        # Add private channels
        @private_channels = {}
        data['private_channels'].each do |element|
          channel = Channel.new(element, self)
          @channels[channel.id] = channel
          @private_channels[channel.recipient.id] = channel
        end

        # Make sure to raise the event
        raise_event(ReadyEvent.new)

        # Afterwards, send out a members request to get the chunk data
        chunk_packet = {
          op: 8,
          d: {
            guild_id: @servers.keys,
            query: '',
            limit: 0
          }
        }.to_json
        @ws.send(chunk_packet)

        LOGGER.good 'Ready'

        # Tell the run method that everything was successful
        @ws_success = true
      when :GUILD_MEMBERS_CHUNK
        id = data['guild_id'].to_i
        members = data['members']

        start_time = Time.now

        members.each do |member|
          # Add the guild_id to the member so we can reuse add_guild_member
          member['guild_id'] = id

          add_guild_member(member)
        end

        duration = Time.now - start_time

        if members.length < 1000
          debug "Got final chunk for server #{id}, parsing took #{duration} seconds"
        else
          debug "Got one chunk for server #{id}, parsing took #{duration} seconds"
        end
      when :MESSAGE_CREATE
        create_message(data)

        message = Message.new(data, self)

        return if message.from_bot? && !should_parse_self

        event = MessageEvent.new(message, self)
        raise_event(event)

        if message.mentions.any? { |user| user.id == @bot_user.id }
          event = MentionEvent.new(message, self)
          raise_event(event)
        end

        if message.channel.private?
          event = PrivateMessageEvent.new(message, self)
          raise_event(event)
        end
      when :MESSAGE_UPDATE
        update_message(data)

        event = MessageEditEvent.new(data, self)
        raise_event(event)
      when :MESSAGE_DELETE
        delete_message(data)

        event = MessageDeleteEvent.new(data, self)
        raise_event(event)
      when :TYPING_START
        start_typing(data)

        begin
          event = TypingEvent.new(data, self)
          raise_event(event)
        rescue Discordrb::Errors::NoPermission
          debug 'Typing started in channel the bot has no access to, ignoring'
        end
      when :PRESENCE_UPDATE
        now_playing = data['game']
        presence_user = user(data['user']['id'].to_i)
        played_before = presence_user.nil? ? nil : presence_user.game
        update_presence(data)

        event = if now_playing != played_before
                  PlayingEvent.new(data, self)
                else
                  PresenceEvent.new(data, self)
                end

        raise_event(event)
      when :VOICE_STATE_UPDATE
        update_voice_state(data)

        event = VoiceStateUpdateEvent.new(data, self)
        raise_event(event)
      when :VOICE_SERVER_UPDATE
        update_voice_server(data)

        # no event as this is irrelevant to users
      when :CHANNEL_CREATE
        create_channel(data)

        event = ChannelCreateEvent.new(data, self)
        raise_event(event)
      when :CHANNEL_UPDATE
        update_channel(data)

        event = ChannelUpdateEvent.new(data, self)
        raise_event(event)
      when :CHANNEL_DELETE
        delete_channel(data)

        event = ChannelDeleteEvent.new(data, self)
        raise_event(event)
      when :GUILD_MEMBER_ADD
        add_guild_member(data)

        event = GuildMemberAddEvent.new(data, self)
        raise_event(event)
      when :GUILD_MEMBER_UPDATE
        update_guild_member(data)

        event = GuildMemberUpdateEvent.new(data, self)
        raise_event(event)
      when :GUILD_MEMBER_REMOVE
        delete_guild_member(data)

        event = GuildMemberDeleteEvent.new(data, self)
        raise_event(event)
      when :GUILD_BAN_ADD
        add_user_ban(data)

        event = UserBanEvent.new(data, self)
        raise_event(event)
      when :GUILD_BAN_REMOVE
        remove_user_ban(data)

        event = UserUnbanEvent.new(data, self)
        raise_event(event)
      when :GUILD_ROLE_UPDATE
        update_guild_role(data)

        event = GuildRoleUpdateEvent.new(data, self)
        raise_event(event)
      when :GUILD_ROLE_CREATE
        create_guild_role(data)

        event = GuildRoleCreateEvent.new(data, self)
        raise_event(event)
      when :GUILD_ROLE_DELETE
        delete_guild_role(data)

        event = GuildRoleDeleteEvent.new(data, self)
        raise_event(event)
      when :GUILD_CREATE
        create_guild(data)

        event = GuildCreateEvent.new(data, self)
        raise_event(event)
      when :GUILD_UPDATE
        update_guild(data)

        event = GuildUpdateEvent.new(data, self)
        raise_event(event)
      when :GUILD_DELETE
        delete_guild(data)

        event = GuildDeleteEvent.new(data, self)
        raise_event(event)
      else
        # another event that we don't support yet
        debug "Event #{packet['t']} has been received but is unsupported, ignoring"
      end
    rescue Exception => e
      log_exception(e)
    end

    def websocket_close(event)
      LOGGER.error('Disconnected from WebSocket!')
      LOGGER.error(" (Reason: #{event.reason})")
      LOGGER.error(" (Code: #{event.code})")
      raise_event(DisconnectEvent.new)
      EM.stop
    end

    def websocket_open(_)
      # Send the initial packet
      packet = {
        op: 2,    # Packet identifier
        d: {      # Packet data
          v: 3,   # WebSocket protocol version
          token: @token,
          properties: { # I'm unsure what these values are for exactly, but they don't appear to impact bot functionality in any way.
            :'$os' => RUBY_PLATFORM.to_s,
            :'$browser' => 'discordrb',
            :'$device' => 'discordrb',
            :'$referrer' => '',
            :'$referring_domain' => ''
          },
          large_threshold: 100
        }
      }

      @ws.send(packet.to_json)
    end

    def send_heartbeat
      millis = Time.now.strftime('%s%L').to_i
      LOGGER.out("Sending heartbeat at #{millis}")
      data = {
        op: 1,
        d: millis
      }

      @ws.send(data.to_json)
    end

    def raise_event(event)
      debug("Raised a #{event.class}")
      handle_awaits(event)

      @event_handlers ||= {}
      handlers = @event_handlers[event.class]
      (handlers || []).each do |handler|
        call_event(handler, event) if handler.matches?(event)
      end
    end

    def call_event(handler, event)
      t = Thread.new do
        @event_threads ||= []
        @current_thread ||= 0

        @event_threads << t
        Thread.current[:discordrb_name] = "et-#{@current_thread += 1}"
        begin
          handler.call(event)
          handler.after_call(event)
        rescue => e
          log_exception(e)
        ensure
          @event_threads.delete(t)
        end
      end
    end

    def handle_awaits(event)
      @awaits ||= {}
      @awaits.each do |_, await|
        key, should_delete = await.match(event)
        next unless key
        debug("should_delete: #{should_delete}")
        @awaits.delete(await.key) if should_delete

        await_event = Discordrb::Events::AwaitEvent.new(await, event, self)
        raise_event(await_event)
      end
    end
  end
end
