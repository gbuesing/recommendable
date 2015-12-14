module Recommendable
  module Rater
    module Recommender
      # Get a list of raters that have been found to be the most similar to
      # self. They are sorted by the calculated similarity value.
      #
      # @param [Fixnum] limit the number of users to return (defaults to 10)
      # @return [Array] An array of instances of your user class
      def similar_raters(limit = 10, offset = 0)
        ids = Recommendable.redis.zrevrange(Recommendable::Helpers::RedisKeyMapper.similarity_set_for(id), 0, -1)

        order = ids.map { |id| "#{Recommendable.config.user_class.quoted_table_name}.#{Recommendable.config.user_class.connection.quote_column_name('id')} = %d DESC" }.join(', ')
        order = self.class.send(:sanitize_sql_for_assignment, [order, *ids])

        Recommendable.query(self.class, ids).order(order).limit(limit).offset(offset)
      end

      private

      # Fetch a list of recommendations for a passed class.
      #
      # @param [String, Symbol, Class] klass the class from which to get recommendations
      # @param [Fixnum] limit the number of recommendations to fetch (defaults to 10)
      # @return [Array] a list of things this person's gonna love
      def recommended_for(klass, limit = 10, offset = 0)
        recommended_set = Recommendable::Helpers::RedisKeyMapper.recommended_set_for(klass, self.id)
        return Recommendable.query(klass, []) unless rated_anything? && Recommendable.redis.zcard(recommended_set) > 0

        ids = Recommendable.redis.zrevrange(recommended_set, 0, -1, :with_scores => true)
        ids = ids.select { |id, score| score > 0 }.map { |pair| pair.first }

        order = ids.map { |id| "#{klass.quoted_table_name}.#{klass.connection.quote_column_name('id')} = %d DESC" }.join(', ')
        order = klass.send(:sanitize_sql_for_assignment, [order, *ids])
        Recommendable.query(klass, ids).order(order).limit(limit).offset(offset)
      end

      # Removes an item from a user's set of recommendations
      # @private
      def unrecommend(obj)
        Recommendable.redis.zrem(Recommendable::Helpers::RedisKeyMapper.recommended_set_for(obj.class, id), obj.id)
        true
      end

      # Removes a user from Recommendable. Called internally on a before_destroy hook.
      # @private
      def remove_from_recommendable!
        sets  = [] # SREM needed
        zsets = [] # ZREM needed
        keys  = [] # DEL  needed

        # Remove from other users' similarity ZSETs
        zsets += Recommendable.redis.keys(Recommendable::Helpers::RedisKeyMapper.similarity_set_for('*'))

        # Remove this user's similarity ZSET
        keys << Recommendable::Helpers::RedisKeyMapper.similarity_set_for(id)

        # For each ratable class...
        Recommendable.config.ratable_classes.each do |klass|
          # Remove this user from any class member's liked_by/disliked_by sets
          sets += Recommendable.redis.keys(Recommendable::Helpers::RedisKeyMapper.liked_by_set_for(klass, '*'))
          sets += Recommendable.redis.keys(Recommendable::Helpers::RedisKeyMapper.disliked_by_set_for(klass, '*'))

          # Remove this user's liked/disliked/hidden/bookmarked/recommended sets for the class
          keys << Recommendable::Helpers::RedisKeyMapper.liked_set_for(klass, id)
          keys << Recommendable::Helpers::RedisKeyMapper.disliked_set_for(klass, id)
          keys << Recommendable::Helpers::RedisKeyMapper.hidden_set_for(klass, id)
          keys << Recommendable::Helpers::RedisKeyMapper.bookmarked_set_for(klass, id)
          keys << Recommendable::Helpers::RedisKeyMapper.recommended_set_for(klass, id)
        end

        Recommendable.redis.pipelined do |redis|
          sets.each { |set| redis.srem(set, id) }
          zsets.each { |zset| redis.zrem(zset, id) }
          redis.del(*keys)
        end
      end
    end
  end
end
