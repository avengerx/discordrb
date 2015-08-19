# These classes hold relevant Discord data, such as messages or channels.

module Discordrb
  class User
    attr_reader :username, :
  end

  class Message
    attr_reader :content, :author, :channel, :timestamp, :id, :mentions

    def initialize(data)
      @content = data['content']
      @author = User.new(data['author'])
      # TODO: Channel
      @timestamp = Time.at(data['timestamp'].to_i)
      @id = data['id'].to_i

      @mentions = []

      data['mentions'].each do |element|
        @mentions << User.new(element)
      end
    end
  end
end