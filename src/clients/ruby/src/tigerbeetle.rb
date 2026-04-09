require_relative "tigerbeetle/version"
require_relative "tigerbeetle/bindings"
require_relative "tigerbeetle/id"
require_relative "tigerbeetle/client"
require "tigerbeetle/tigerbeetle"

module TigerBeetle
  @id_generator = IdGenerator.new

  def self.generate_id
    @id_generator.generate
  end
end
