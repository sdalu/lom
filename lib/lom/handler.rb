require 'forwardable'

class LOM
    using LDAP::Extensions

    
    # Set the LDAP handler to use
    #
    # It can be a Net::LDAP handler, or a callable (proc, lambda, ...)
    # building one. A Net::LDAP handler is not thread safe, so a
    # callable is required as soon as LOM is used from several threads:
    # it will be called once per thread (or fiber), and the resulting
    # handler reused by that thread.
    #
    # ~~~
    # LOM.lh = -> { Net::LDAP.connect('ldap://127.0.0.1')
    #                        .tap { it.auth(dn, password) } }
    # ~~~
    #
    def self.lh=(lh)
        @lh = lh
    end

    # Get the LDAP handler to use
    #
    # In order of preference:
    #
    # * the handler set using lh=
    # * the LH constant in this scope or parent scope
    # * the one defined in $lh
    #
    # If the handler is a callable, the handler built by it for the
    # current thread is returned.
    #
    def self.lh
        materialize_lh(lh_source)
    end   

    # Get the LDAP handler source (handler or callable), see lh
    #
    # @api private
    #
    def self.lh_source
        @lh || (const_defined?(:LH) && const_get(:LH)) || $lh
    end

    # Resolve a handler source to a usable LDAP handler.
    #
    # A callable is called once per thread (or fiber) and its result
    # cached for that thread, anything else is returned unchanged.
    #
    # @api private
    #
    def self.materialize_lh(src)
        return src unless src.respond_to?(:call)
        (Thread.current[:__lom_lh] ||= {}.compare_by_identity)[src] ||=
            src.call
    end

    # Run the block with a single LDAP connection opened and bound,
    # which is reused by all the LDAP operations of the block,
    # instead of one connection per operation.
    #
    # This is only done if the handler is a callable (see lh=), as an
    # opened connection must not be shared between threads, otherwise
    # the block is simply run.
    #
    # If the connection or bind fails, the block is still run, falling
    # back to one connection per operation.
    #
    # Nested calls reuse the already opened connection.
    #
    # @return the block value
    #
    def self.open
        src = lh_source
        return yield unless src.respond_to?(:call)

        lh     = materialize_lh(src)
        opened = (Thread.current[:__lom_opened] ||= {}.compare_by_identity)
        return yield if opened[lh]

        entered = false
        result  = nil
        begin
            lh.open do
                code = lh.get_operation_result.code
                next unless code == Net::LDAP::ResultCodeSuccess
                opened[lh] = { depth: 0, dirty: false }
                entered    = true
                begin
                    result = yield
                ensure
                    opened.delete(lh)
                end
            end
        rescue Net::LDAP::Error, SystemCallError, IOError
            raise if entered
        end
        entered ? result : yield
    end

    # Run the block performing a search on the handler.
    #
    # If the handler connection was opened by LOM.open and the search
    # is left before completion (break, exception, ...), the unread
    # search results would be kept until the end of LOM.open, so the
    # connection is replaced by a new one, once no other search is
    # using it.
    #
    # @api private
    #
    def self.searching(lh)
        state = Thread.current[:__lom_opened]&.[](lh)
        return yield if state.nil?

        state[:depth] += 1
        done = false
        begin
            yield.tap { done = true }
        ensure
            state[:depth] -= 1
            state[:dirty] ||= !done
            reopen(lh, state) if state[:dirty] && state[:depth].zero?
        end
    end

    # Replace the connection opened by LOM.open with a new one.
    # If it can't be opened and bound, operations fall back to
    # one connection per operation.
    #
    # @note relies on Net::LDAP internals (@open_connection, @auth,
    #       #new_connection) as used by Net::LDAP#open
    #
    # @api private
    #
    def self.reopen(lh, state)
        state[:dirty] = false
        begin
            lh.instance_variable_get(:@open_connection)&.close
        rescue StandardError
        end
        lh.instance_variable_set(:@open_connection, nil)

        conn = lh.send(:new_connection)
        res  = conn.bind(lh.instance_variable_get(:@auth))
        if res.result_code == Net::LDAP::ResultCodeSuccess
            lh.instance_variable_set(:@open_connection, conn)
        else
            conn.close
        end
    rescue Net::LDAP::Error, SystemCallError, IOError
        conn&.close rescue nil
    end

    
    # extend Forwardable
    #
    # def self.connect(*args)
    #     self.new(Net::LDAP.connect(*args))
    # end
    #
    # def initialize(lh)
    #     @lh = lh
    # end
    #
    # def_delegator :@lh, :search
    # def_delegator :@lh, :update
    # def_delegator :@lh, :modify
    # def_delegator :@lh, :add
    # def_delegator :@lh, :delete

end
