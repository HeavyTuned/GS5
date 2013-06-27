# encoding: UTF-8

class SipAccount < ActiveRecord::Base
  include ActionView::Helpers::TextHelper

  attr_accessible :auth_name, :caller_name, :password, :voicemail_pin, 
                  :tenant_id, :call_waiting, :clir, :clip_no_screening,
                  :clip, :description, :callforward_rules_act_per_sip_account,
                  :hotdeskable, :gs_node_id, :language_code, :voicemail_account_id


  # Associations:
  #
  belongs_to :sip_accountable, :polymorphic => true, :touch => true
  
  has_many :phone_sip_accounts, :uniq => true
  has_many :phones, :through => :phone_sip_accounts
  
  has_many :phone_numbers, :as => :phone_numberable, :dependent => :destroy
  has_many :call_forwards, :as => :call_forwardable, :dependent => :destroy

  belongs_to :tenant
  belongs_to :sip_domain

  has_many :softkeys, :dependent => :destroy, :order => :position

  has_many :voicemail_messages, :foreign_key => 'username', :primary_key => 'auth_name'

  has_many :call_histories, :as => :call_historyable, :dependent => :destroy

  belongs_to :gs_node

  belongs_to :language, :foreign_key => 'language_code', :primary_key => 'code'

  has_many :group_memberships, :as => :item, :dependent => :destroy, :uniq => true
  has_many :groups, :through => :group_memberships

  has_many :ringtones, :as => :ringtoneable, :dependent => :destroy

  has_many :call_legs, :class_name => 'Call'
  has_many :b_call_legs, :class_name => 'Call', :foreign_key => 'b_sip_account_id'

  has_many :acd_agents, :as => :destination, :dependent => :destroy
  has_many :switchboard_entries, :dependent => :destroy

  has_many :voicemail_accounts, :as => :voicemail_accountable, :dependent => :destroy
  belongs_to :voicemail_account

  has_many :pager_groups, :dependent => :destroy

  # Delegations:
  #
  delegate :host, :to => :sip_domain, :allow_nil => true
  delegate :realm, :to => :sip_domain, :allow_nil => true

  # Validations:
  #
  validates_presence_of :caller_name
  validates_presence_of :sip_accountable
  validates_presence_of :tenant
  validates_presence_of :sip_domain
  
  validate_sip_password :password
  
  validates_uniqueness_of :auth_name, :scope => :sip_domain_id

  # Before and after hooks:
  # 
  before_save :save_value_of_to_s
  before_validation :find_and_set_tenant_id
  before_validation :set_sip_domain_id
  before_validation :convert_umlauts_in_caller_name
  before_destroy :remove_sip_accounts_or_logout_phones

  # Sync other nodes when this is a cluster.
  #
  validates_presence_of :uuid
  validates_uniqueness_of :uuid

  after_create { self.create_on_other_gs_nodes('sip_accountable', self.sip_accountable.try(:uuid)) }
  after_create :create_default_group_memberships
  after_destroy :destroy_on_other_gs_nodes
  after_update { self.update_on_other_gs_nodes('sip_accountable', self.sip_accountable.try(:uuid)) }

  after_update :log_out_phone_if_not_local

  def to_s
    truncate((self.caller_name || "SipAccount ID #{self.id}"), :length => GsParameter.get('TO_S_MAX_CALLER_NAME_LENGTH')) + " (#{truncate(self.auth_name, :length => GsParameter.get('TO_S_MAX_LENGTH_OF_AUTH_NAME'))}@...#{self.host.split(/\./)[2,3].to_a.join('.') if self.host })"
  end

  def calls
    self.call_legs + self.b_call_legs
  end
  
  def call_forwarding_toggle( call_forwarding_service, to_voicemail = nil )
    if ! self.phone_numbers.first
      errors.add(:base, "You must provide at least one phone number")
    end

    service_id = CallForwardCase.where(:value => call_forwarding_service).first.id

    call_forwarding_master = self.phone_numbers.first.call_forwards.where(:call_forward_case_id => service_id).order(:active).all(:conditions => 'source IS NULL OR source = ""').first
    if ! call_forwarding_master
      errors.add(:base, "No call forwarding entries found that could be toggled")
      return false
    end

    if call_forwarding_master.active
      call_forwarding_master.active = false
    else
      if call_forwarding_service = 'assistant' && call_forwarding_master.destinationable_type == 'HuntGroup' && call_forwarding_master.destinationable
        if call_forwarding_master.destinationable.hunt_group_members.where(:active => true).count > 0
          call_forwarding_master.active = true
        else
          call_forwarding_master.active = false
        end
      end
    end

    self.phone_numbers.each do |phone_number|
      call_forwarding = phone_number.call_forwards.where(:call_forward_case_id => service_id).order(:active).all(:conditions => 'source IS NULL OR source = ""').first
      if ! call_forwarding
        call_forwarding = CallForward.new()
        call_forwarding.call_forwardable = phone_number
      end

      if to_voicemail == nil 
        to_voicemail = call_forwarding_master.to_voicemail
      end

      call_forwarding.call_forward_case_id = call_forwarding_master.call_forward_case_id
      call_forwarding.timeout = call_forwarding_master.timeout
      call_forwarding.destination = call_forwarding_master.destination
      call_forwarding.source = call_forwarding_master.source
      call_forwarding.depth = call_forwarding_master.depth
      call_forwarding.active = call_forwarding_master.active
      call_forwarding.to_voicemail = to_voicemail

      if ! call_forwarding.save
        call_forwarding.errors.messages.each_with_index do |(error_key, error_message), index|
          errors.add(error_key, "number: #{phone_number}: #{error_message}")
        end
      end
    end

    if errors.empty? 
      return call_forwarding_master
    end

    return false
  end

  def registration
    return SipRegistration.where(:sip_user => self.auth_name).first
  end

  def call( phone_number, caller_id_number = nil, caller_id_name = 'Call', auto_answer = false )
    require 'freeswitch_event'
    origination_uuid = UUID.new.generate
    if FreeswitchAPI.execute(
      'originate', 
      "{origination_uuid=#{origination_uuid},origination_caller_id_number='#{caller_id_number||phone_number}',origination_caller_id_name='#{caller_id_name}',sip_auto_answer='#{auto_answer}'}user/#{self.auth_name} #{phone_number}", 
      true)
      return origination_uuid
    end
  end

  def target_group_ids_by_permission(permission)
    target_groups = Group.union(self.groups.collect{|g| g.permission_targets(permission)})
    target_groups = target_groups + Group.union(self.sip_accountable.groups.collect{|g| g.permission_targets(permission)})

    return target_groups
  end

  def target_sip_accounts_by_permission(permission)
    sip_accounts = []
    GroupMembership.where(:group_id => target_group_ids_by_permission(permission)).each do |group_membership|
      if group_membership.item.class == User || group_membership.item.class == Tenant
        sip_accounts = sip_accounts + group_membership.item.sip_accounts
      elsif group_membership.item.class == SipAccount
        sip_accounts << group_membership.item
      end
        
      sip_accounts = sip_accounts.uniq
    end

    return sip_accounts
  end

  def status
    states = Array.new

    self.call_legs.each do |call_leg|
      states << {
        :status => call_leg.b_callstate || call_leg.callstate,
        :status_channel => call_leg.callstate,
        :caller => true,
        :endpoint_name => call_leg.callee_name,
        :endpoint_number => call_leg.destination,
        :endpoint_sip_account_id => call_leg.b_sip_account_id,
        :start_stamp => call_leg.start_stamp,
        :secure => call_leg.secure,
      }
    end

    self.b_call_legs.each do |call_leg|
      call_status = 
      states << {
        :status => call_leg.b_callstate,
        :status_channel => call_leg.b_callstate,
        :caller => false,
        :endpoint_name => call_leg.caller_id_name,
        :endpoint_number => call_leg.caller_id_number,
        :endpoint_sip_account_id => call_leg.sip_account_id,
        :start_stamp => call_leg.start_stamp,
        :secure => call_leg.b_secure,
      }
    end

    return states
  end

  private
      
  def save_value_of_to_s
    self.value_of_to_s = self.to_s
  end
  
  def find_and_set_tenant_id
      if self.new_record? and self.tenant_id != nil
        return        
      else
        tenant = case self.sip_accountable_type
          when 'Tenant'    ; sip_accountable
          when 'UserGroup' ; sip_accountable.tenant
          when 'User'      ; sip_accountable.try(:current_tenant) || sip_accountable.try(:tenants).try(:last)
          else nil
        end
        self.tenant_id = tenant.id if tenant != nil
      end
  end
  
  def set_sip_domain_id
    self.sip_domain_id = self.tenant.try(:sip_domain_id)
  end
  
  def convert_umlauts_in_caller_name
    if !self.caller_name.blank?
      self.caller_name = self.caller_name.sub(/ä/,'ae').
                              sub(/Ä/,'Ae').
                              sub(/ü/,'ue').
                              sub(/Ü/,'Ue').
                              sub(/ö/,'oe').
                              sub(/Ö/,'Oe').
                              sub(/ß/,'ss')

      self.caller_name = self.caller_name.gsub(/[^a-zA-Z0-9\-\,\:\. ]/,'_')
    end
  end

  # Make sure that a tenant phone goes back to the tenant and doesn't
  # get deleted with this user.
  #
  def remove_sip_accounts_or_logout_phones
    self.phones.each do |phone|
      if phone.sip_accounts.where(:sip_accountable_type => 'Tenant').count > 0
        phone.user_logout
      else
        PhoneSipAccount.delete_all(:sip_account_id => self.id)
      end
    end
    self.reload
  end

  # log out phone if sip_account is not on this node
  def log_out_phone_if_not_local
    if self.gs_node_id && GsNode.count > 1 && ! GsNode.where(:ip_address => GsParameter.get('HOMEBASE_IP_ADDRESS'), :id => self.gs_node_id).first
      self.phones.each do |phone|
        phone.user_logout;
      end
    end
  end

  def create_default_group_memberships
    default_groups = Hash.new()
    templates = GsParameter.get('SipAccount', 'group', 'default')
    if templates.class == Array
      templates.each do |group_name|
        default_groups[group_name] = true
      end
    end

    templates = GsParameter.get("SipAccount.#{self.sip_accountable_type}", 'group', 'default')
    if templates.class == Array
      templates.each do |group_name|
        default_groups[group_name] = true
      end
    end

    default_groups.each do |group_name, value|
      group = Group.where(:name => group_name).first
      if group
        self.group_memberships.create(:group_id => group.id)
      end
    end
  end

end
