#!/usr/bin/env ruby

require 'bundler'
Bundler.require :default
require 'angelo/main'
require File.join File.expand_path('..', __FILE__), 'chatdemo/redis'

addr '0.0.0.0'
port ENV['PORT'] if ENV['PORT']

# response for the post route
#
PUBLISHED = { status: 'published!' }

# task subscribed to channel flags
#
$subscriptions = {}

# gimmie dat channel parameter as a symbol
#
before do
  @channel = params[:channel].to_sym rescue nil
end

# render the index page
#
get '/' do
  erb :index
end

# render wss for production, ws for dev
#
get '/assets/js/application.js' do
  content_type :js
  @scheme = ENV['RACK_ENV'] == 'production' ? 'wss://' : 'ws://'
  erb :application
end

# post a message to a channel without being subscribed to the channel!
#
post '/:channel' do
  content_type :json
  ChatDemo::Redis.with do |r|
    r.publish ChatDemo::Redis::CHANNEL_KEY % @channel, sanitize(params[:msg])
  end
  PUBLISHED
end

# subscribe to a channel
#
websocket '/:channel' do |ws|

  # must specify a channel!
  #
  raise RequestError.new 'no channel specified!' unless @channel

  # add this websocket to the channel stash
  #
  websockets[@channel] << ws

  # run the async subscription task unless it's already running
  #
  async :subscribe, @channel unless $subscriptions[@channel]

  # while this websocket is connected, pipe every incoming message
  # to the redis channel
  #
  ws.on_message do |msg|
    ChatDemo::Redis.with do |r|
      r.publish ChatDemo::Redis::CHANNEL_KEY % @channel, sanitize(msg)
    end
  end
end



# channel subscription task, defined on the reactor, called with
# `async` above to begin piping all channel messages to all websockets
# subscribed to that channel (i.e. in that channel stash)
#
task :subscribe do |channel|

  # flag this channel as subscribed
  #
  $subscriptions[channel] = true

  # catch a no-more-subscribed-websockets event
  #
  catch :empty do

    # actually subscribe to the redis channel for the chat messages
    #
    ChatDemo::Redis::new_redis.subscribe ChatDemo::Redis::CHANNEL_KEY % channel do |on|
      on.message do |c, msg|

        # on every message, pipe it out to the connected websockets
        #
        websockets[channel].each {|ws| ws.write msg}

        # throw if there are no more connected websockets
        #
        throw :empty if websockets[channel].length == 0
      end
    end
  end

  # unflag this channel as subscribed before ending the task
  #
  $subscriptions.delete channel
end

private

def sanitize(message)
  json = JSON.parse(message)
  json.each {|key, value| json[key] = ERB::Util.html_escape(value) }
  JSON.generate(json)
end
