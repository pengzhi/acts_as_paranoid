module Caboose #:nodoc:
  module Acts #:nodoc:
    # Overrides some basic methods for the current model so that calling #destroy sets a 'deleted_at' field to the current timestamp.
    # This assumes the table has a deleted_at date/time field.  Most normal model operations will work, but there will be some oddities.
    #
    #   class Widget < ActiveRecord::Base
    #     acts_as_paranoid
    #   end
    #
    #   Widget.find(:all)
    #   # SELECT * FROM widgets WHERE widgets.deleted_at IS NULL
    #
    #   Widget.find(:first, :conditions => ['title = ?', 'test'], :order => 'title')
    #   # SELECT * FROM widgets WHERE widgets.deleted_at IS NULL AND title = 'test' ORDER BY title LIMIT 1
    #
    #   Widget.find_with_deleted(:all)
    #   # SELECT * FROM widgets
    #
    #   Widget.find(:all, :with_deleted => true)
    #   # SELECT * FROM widgets
    #
    #   Widget.count
    #   # SELECT COUNT(*) FROM widgets WHERE widgets.deleted_at IS NULL
    #
    #   Widget.count ['title = ?', 'test']
    #   # SELECT COUNT(*) FROM widgets WHERE widgets.deleted_at IS NULL AND title = 'test'
    #
    #   Widget.count_with_deleted
    #   # SELECT COUNT(*) FROM widgets
    #
    #   @widget.destroy
    #   # UPDATE widgets SET deleted_at = '2005-09-17 17:46:36' WHERE id = 1
    #
    #   @widget.destroy!
    #   # DELETE FROM widgets WHERE id = 1
    # 
    module Paranoid
      module ActiveRecord
        def self.included(base) # :nodoc:
          base.extend ClassMethods
          class << base
            alias_method :validate_find_options_without_deleted, :validate_find_options
            alias_method :validate_find_options, :validate_find_options_with_deleted
          end
        end

        module ClassMethods
          def acts_as_paranoid
            unless paranoid? # don't let AR call this twice
              alias_method :destroy_without_callbacks!, :destroy_without_callbacks
              class << self
                alias_method :original_find, :find
                alias_method :count_with_deleted, :count
                alias_method :clobbering_with_scope, :with_scope
              end
            end
            include InstanceMethods
          end
          
          def paranoid?
            self.included_modules.include?(InstanceMethods)
          end
          
          protected
          def validate_find_options_with_deleted(options)
            options.assert_valid_keys [:conditions, :group, :include, :joins, :limit, :offset, :order, :select, :readonly, :with_deleted]
          end
        end
    
        module InstanceMethods #:nodoc:
          def self.included(base) # :nodoc:
            base.extend ClassMethods
          end
      
          module ClassMethods
            def find(*args)
              options = extract_options_from_args!(args)
              call_original_find = lambda { original_find(*(args << options)) }
            
              if !options[:with_deleted]
                with_deleted_scope { return call_original_find.call }
              end
            
              call_original_find.call
            end

            def find_with_deleted(*args)
              original_find(*(args << extract_options_from_args!(args).merge(:with_deleted => true)))
            end

            def count(conditions = nil, joins = nil)
              with_deleted_scope { count_with_deleted(conditions, joins) }
            end

            def with_scope(method_scoping = {}, is_new_scope = true)
              # Dup first and second level of hash (method and params).
              method_scoping = method_scoping.inject({}) do |hash, (method, params)|
                hash[method] = params.dup
                hash
              end

              method_scoping.assert_valid_keys [:find, :create]
              if f = method_scoping[:find]
                f.assert_valid_keys [:conditions, :joins, :offset, :limit, :readonly]
                f[:readonly] = true if !f[:joins].blank? && !f.has_key?(:readonly)
              end

              raise ArgumentError, "Nested scopes are not yet supported: #{scoped_methods.inspect}" unless scoped_methods.nil?

              self.scoped_methods = method_scoping
              yield
            ensure
              self.scoped_methods = nil if is_new_scope
            end

            protected
            def with_deleted_scope(&block)
              deleted_cond = "#{table_name}.deleted_at IS NULL"
              if scoped_methods.nil?
                is_new_scope = true
                current_scope = {}
              else
                is_new_scope = false
                current_scope = scoped_methods.clone
                self.scoped_methods = nil
              end
            
              current_scope ||= {}
              current_scope[:find] ||= {}
              if not current_scope[:find][:conditions] =~ /#{deleted_cond}/
                current_scope[:find][:conditions] = current_scope[:find][:conditions].nil? ?
                  deleted_cond :
                  "(#{current_scope[:find][:conditions]}) AND #{deleted_cond}"
              end
            
              with_scope(current_scope, is_new_scope, &block)
            end
          end

          def destroy_without_callbacks
            unless new_record?
              sql = self.class.send(:sanitize_sql,
                ["UPDATE #{self.class.table_name} SET deleted_at = ? WHERE id = ?", 
                  self.class.default_timezone == :utc ? Time.now.utc : Time.now, id])
              self.connection.update(sql)
            end
            freeze
          end
        
          def destroy_with_callbacks!
            return false if callback(:before_destroy) == false
            result = destroy_without_callbacks!
            callback(:after_destroy)
            result
          end
        
          def destroy!
            transaction { destroy_with_callbacks! }
          end
        end
      end

      module AssociationProxy #:nodoc:
        protected
        def find_with_deleted?
          @owner.class.paranoid? and @owner.deleted_at
        end
  
        def options_with_deleted!(options)
          options[:with_deleted] = find_with_deleted? if @association_class.paranoid?
          options
        end
      end

      module BelongsToAssociation #:nodoc:
        def self.included(base)
          base.send :alias_method, :find_target_without_deleted, :find_target
          base.send :alias_method, :find_target, :find_target_with_deleted
        end

        private
        def find_target_with_deleted
          options = { :include => @options[:include] }
          options[:conditions]   = interpolate_sql(@options[:conditions]) if @options[:conditions]
          options_with_deleted! options
        
          @association_class.find(@owner[@association_class_primary_key_name], options)
        end
      end

      module HasOneAssociation #:nodoc:
        def self.included(base)
          base.send :alias_method, :find_target_without_deleted, :find_target
          base.send :alias_method, :find_target, :find_target_with_deleted
        end

        private
        def find_target_with_deleted
          @association_class.find :first, options_with_deleted!(:conditions   => @finder_sql, 
                                                                :order        => @options[:order], 
                                                                :include      => @options[:include])
        end
      end

      module HasManyAssociation #:nodoc:
        def self.included(base)
          base.send :alias_method, :find_target_without_deleted, :find_target
          base.send :alias_method, :find_target, :find_target_with_deleted
          base.send :alias_method, :count_records_without_deleted, :count_records
          base.send :alias_method, :count_records, :count_records_with_deleted
        end

        private
        def find_target_with_deleted
          if @options[:finder_sql]
            @association_class.find_by_sql(@finder_sql)
          else
            @association_class.find(:all, 
              options_with_deleted!(:conditions   => @finder_sql,
                                    :order        => @options[:order], 
                                    :limit        => @options[:limit],
                                    :joins        => @options[:joins],
                                    :include      => @options[:include],
                                    :group        => @options[:group])
            )
          end
        end

        def count_records_with_deleted
          count = if has_cached_counter?
            @owner.send(:read_attribute, cached_counter_attribute_name)
          elsif @options[:counter_sql]
            @association_class.count_by_sql(@counter_sql)
          else
            @association_class.send((find_with_deleted? ? :count_with_deleted : :count), @counter_sql)
          end
          
          @target = [] and loaded if count == 0
          
          return count
        end
      end

      module HasAndBelongsToManyAssociation #:nodoc:
        def self.included(base)
          base.send :alias_method, :find_target_without_deleted, :find_target
          base.send :alias_method, :find_target, :find_target_with_deleted
        end

        private
        def find_target_with_deleted
          if @options[:finder_sql]
            records = @association_class.find_by_sql(@finder_sql)
          else
            records = find(:all, options_with_deleted!(:include => @options[:include]))
          end
          
          @options[:uniq] ? uniq(records) : records
        end
      end
    end
  end
end

ActiveRecord::Base.send                                         :include, Caboose::Acts::Paranoid::ActiveRecord
ActiveRecord::Associations::AssociationProxy.send               :include, Caboose::Acts::Paranoid::AssociationProxy
ActiveRecord::Associations::BelongsToAssociation.send           :include, Caboose::Acts::Paranoid::BelongsToAssociation
ActiveRecord::Associations::HasOneAssociation.send              :include, Caboose::Acts::Paranoid::HasOneAssociation
ActiveRecord::Associations::HasManyAssociation.send             :include, Caboose::Acts::Paranoid::HasManyAssociation
ActiveRecord::Associations::HasAndBelongsToManyAssociation.send :include, Caboose::Acts::Paranoid::HasAndBelongsToManyAssociation