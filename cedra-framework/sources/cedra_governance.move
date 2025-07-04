///
/// CedraGovernance represents the on-chain governance of the Cedra network. Voting power is calculated based on the
/// current epoch's voting power of the proposer or voter's backing stake pool. In addition, for it to count,
/// the stake pool's lockup needs to be at least as long as the proposal's duration.
///
/// It provides the following flow:
/// 1. Proposers can create a proposal by calling CedraGovernance::create_proposal. The proposer's backing stake pool
/// needs to have the minimum proposer stake required. Off-chain components can subscribe to CreateProposalEvent to
/// track proposal creation and proposal ids.
/// 2. Voters can vote on a proposal. Their voting power is derived from the backing stake pool. A stake pool can vote
/// on a proposal multiple times as long as the total voting power of these votes doesn't exceed its total voting power.
module cedra_framework::cedra_governance {
    use std::error;
    use std::option;
    use std::signer;
    use std::string::{Self, String, utf8};
    use std::vector;
    use std::features;

    use cedra_std::math64::min;
    use cedra_std::simple_map::{Self, SimpleMap};
    use cedra_std::smart_table::{Self, SmartTable};
    use cedra_std::table::{Self, Table};

    use cedra_framework::account::{Self, SignerCapability, create_signer_with_capability};
    use cedra_framework::coin;
    use cedra_framework::event::{Self, EventHandle};
    use cedra_framework::governance_proposal::{Self, GovernanceProposal};
    use cedra_framework::stake;
    use cedra_framework::staking_config;
    use cedra_framework::system_addresses;
    use cedra_framework::cedra_coin::{Self, CedraCoin};
    use cedra_framework::consensus_config;
    use cedra_framework::permissioned_signer;
    use cedra_framework::randomness_config;
    use cedra_framework::reconfiguration_with_dkg;
    use cedra_framework::timestamp;
    use cedra_framework::voting;

    /// The specified stake pool does not have sufficient stake to create a proposal
    const EINSUFFICIENT_PROPOSER_STAKE: u64 = 1;
    /// This account is not the designated voter of the specified stake pool
    const ENOT_DELEGATED_VOTER: u64 = 2;
    /// The specified stake pool does not have long enough remaining lockup to create a proposal or vote
    const EINSUFFICIENT_STAKE_LOCKUP: u64 = 3;
    /// The specified stake pool has already been used to vote on the same proposal
    const EALREADY_VOTED: u64 = 4;
    /// The specified stake pool must be part of the validator set
    const ENO_VOTING_POWER: u64 = 5;
    /// Proposal is not ready to be resolved. Waiting on time or votes
    const EPROPOSAL_NOT_RESOLVABLE_YET: u64 = 6;
    /// The proposal has not been resolved yet
    const EPROPOSAL_NOT_RESOLVED_YET: u64 = 8;
    /// Metadata location cannot be longer than 256 chars
    const EMETADATA_LOCATION_TOO_LONG: u64 = 9;
    /// Metadata hash cannot be longer than 256 chars
    const EMETADATA_HASH_TOO_LONG: u64 = 10;
    /// Account is not authorized to call this function.
    const EUNAUTHORIZED: u64 = 11;
    /// The stake pool is using voting power more than it has.
    const EVOTING_POWER_OVERFLOW: u64 = 12;
    /// Partial voting feature hasn't been properly initialized.
    const EPARTIAL_VOTING_NOT_INITIALIZED: u64 = 13;
    /// The proposal in the argument is not a partial voting proposal.
    const ENOT_PARTIAL_VOTING_PROPOSAL: u64 = 14;
    /// The proposal has expired.
    const EPROPOSAL_EXPIRED: u64 = 15;
    /// Current permissioned signer cannot perform governance operations.
    const ENO_GOVERNANCE_PERMISSION: u64 = 16;

    /// This matches the same enum const in voting. We have to duplicate it as Move doesn't have support for enums yet.
    const PROPOSAL_STATE_SUCCEEDED: u64 = 1;

    const MAX_U64: u64 = 18446744073709551615;

    /// Proposal metadata attribute keys.
    const METADATA_LOCATION_KEY: vector<u8> = b"metadata_location";
    const METADATA_HASH_KEY: vector<u8> = b"metadata_hash";

    /// Store the SignerCapabilities of accounts under the on-chain governance's control.
    struct GovernanceResponsbility has key {
        signer_caps: SimpleMap<address, SignerCapability>,
    }

    /// Configurations of the CedraGovernance, set during Genesis and can be updated by the same process offered
    /// by this CedraGovernance module.
    struct GovernanceConfig has key {
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    }

    struct RecordKey has copy, drop, store {
        stake_pool: address,
        proposal_id: u64,
    }

    /// Records to track the proposals each stake pool has been used to vote on.
    struct VotingRecords has key {
        votes: Table<RecordKey, bool>
    }

    /// Records to track the voting power usage of each stake pool on each proposal.
    struct VotingRecordsV2 has key {
        votes: SmartTable<RecordKey, u64>
    }

    /// Used to track which execution script hashes have been approved by governance.
    /// This is required to bypass cases where the execution scripts exceed the size limit imposed by mempool.
    struct ApprovedExecutionHashes has key {
        hashes: SimpleMap<u64, vector<u8>>,
    }

    /// Events generated by interactions with the CedraGovernance module.
    struct GovernanceEvents has key {
        create_proposal_events: EventHandle<CreateProposalEvent>,
        update_config_events: EventHandle<UpdateConfigEvent>,
        vote_events: EventHandle<VoteEvent>,
    }

    /// Event emitted when a proposal is created.
    struct CreateProposalEvent has drop, store {
        proposer: address,
        stake_pool: address,
        proposal_id: u64,
        execution_hash: vector<u8>,
        proposal_metadata: SimpleMap<String, vector<u8>>,
    }

    /// Event emitted when there's a vote on a proposa;
    struct VoteEvent has drop, store {
        proposal_id: u64,
        voter: address,
        stake_pool: address,
        num_votes: u64,
        should_pass: bool,
    }

    /// Event emitted when the governance configs are updated.
    struct UpdateConfigEvent has drop, store {
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    }

    #[event]
    /// Event emitted when a proposal is created.
    struct CreateProposal has drop, store {
        proposer: address,
        stake_pool: address,
        proposal_id: u64,
        execution_hash: vector<u8>,
        proposal_metadata: SimpleMap<String, vector<u8>>,
    }

    #[event]
    /// Event emitted when there's a vote on a proposa;
    struct Vote has drop, store {
        proposal_id: u64,
        voter: address,
        stake_pool: address,
        num_votes: u64,
        should_pass: bool,
    }

    #[event]
    /// Event emitted when the governance configs are updated.
    struct UpdateConfig has drop, store {
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    }

    struct GovernancePermission has copy, drop, store {}

    /// Permissions
    inline fun check_governance_permission(s: &signer) {
        assert!(
            permissioned_signer::check_permission_exists(s, GovernancePermission {}),
            error::permission_denied(ENO_GOVERNANCE_PERMISSION),
        );
    }

    /// Grant permission to perform governance operations on behalf of the master signer.
    public fun grant_permission(master: &signer, permissioned_signer: &signer) {
        permissioned_signer::authorize_unlimited(master, permissioned_signer, GovernancePermission {})
    }

    /// Can be called during genesis or by the governance itself.
    /// Stores the signer capability for a given address.
    public fun store_signer_cap(
        cedra_framework: &signer,
        signer_address: address,
        signer_cap: SignerCapability,
    ) acquires GovernanceResponsbility {
        system_addresses::assert_cedra_framework(cedra_framework);
        system_addresses::assert_framework_reserved(signer_address);

        if (!exists<GovernanceResponsbility>(@cedra_framework)) {
            move_to(
                cedra_framework,
                GovernanceResponsbility { signer_caps: simple_map::create<address, SignerCapability>() }
            );
        };

        let signer_caps = &mut borrow_global_mut<GovernanceResponsbility>(@cedra_framework).signer_caps;
        simple_map::add(signer_caps, signer_address, signer_cap);
    }

    /// Initializes the state for Cedra Governance. Can only be called during Genesis with a signer
    /// for the cedra_framework (0x1) account.
    /// This function is private because it's called directly from the vm.
    fun initialize(
        cedra_framework: &signer,
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    ) {
        system_addresses::assert_cedra_framework(cedra_framework);

        voting::register<GovernanceProposal>(cedra_framework);
        initialize_partial_voting(cedra_framework);
        move_to(cedra_framework, GovernanceConfig {
            voting_duration_secs,
            min_voting_threshold,
            required_proposer_stake,
        });
        move_to(cedra_framework, GovernanceEvents {
            create_proposal_events: account::new_event_handle<CreateProposalEvent>(cedra_framework),
            update_config_events: account::new_event_handle<UpdateConfigEvent>(cedra_framework),
            vote_events: account::new_event_handle<VoteEvent>(cedra_framework),
        });
        move_to(cedra_framework, VotingRecords {
            votes: table::new(),
        });
        move_to(cedra_framework, ApprovedExecutionHashes {
            hashes: simple_map::create<u64, vector<u8>>(),
        })
    }

    /// Update the governance configurations. This can only be called as part of resolving a proposal in this same
    /// CedraGovernance.
    public fun update_governance_config(
        cedra_framework: &signer,
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    ) acquires GovernanceConfig, GovernanceEvents {
        system_addresses::assert_cedra_framework(cedra_framework);

        let governance_config = borrow_global_mut<GovernanceConfig>(@cedra_framework);
        governance_config.voting_duration_secs = voting_duration_secs;
        governance_config.min_voting_threshold = min_voting_threshold;
        governance_config.required_proposer_stake = required_proposer_stake;

        if (std::features::module_event_migration_enabled()) {
            event::emit(
                UpdateConfig {
                    min_voting_threshold,
                    required_proposer_stake,
                    voting_duration_secs
                },
            )
        } else {
            let events = borrow_global_mut<GovernanceEvents>(@cedra_framework);
            event::emit_event<UpdateConfigEvent>(
                &mut events.update_config_events,
                UpdateConfigEvent {
                    min_voting_threshold,
                    required_proposer_stake,
                    voting_duration_secs
                },
            );
        };
    }

    /// Initializes the state for Cedra Governance partial voting. Can only be called through Cedra governance
    /// proposals with a signer for the cedra_framework (0x1) account.
    public fun initialize_partial_voting(
        cedra_framework: &signer,
    ) {
        system_addresses::assert_cedra_framework(cedra_framework);

        move_to(cedra_framework, VotingRecordsV2 {
            votes: smart_table::new(),
        });
    }

    #[view]
    public fun get_voting_duration_secs(): u64 acquires GovernanceConfig {
        borrow_global<GovernanceConfig>(@cedra_framework).voting_duration_secs
    }

    #[view]
    public fun get_min_voting_threshold(): u128 acquires GovernanceConfig {
        borrow_global<GovernanceConfig>(@cedra_framework).min_voting_threshold
    }

    #[view]
    public fun get_required_proposer_stake(): u64 acquires GovernanceConfig {
        borrow_global<GovernanceConfig>(@cedra_framework).required_proposer_stake
    }

    #[view]
    /// Return true if a stake pool has already voted on a proposal before partial governance voting is enabled.
    public fun has_entirely_voted(stake_pool: address, proposal_id: u64): bool acquires VotingRecords {
        let record_key = RecordKey {
            stake_pool,
            proposal_id,
        };
        // If a stake pool has already voted on a proposal before partial governance voting is enabled,
        // there is a record in VotingRecords.
        let voting_records = borrow_global<VotingRecords>(@cedra_framework);
        table::contains(&voting_records.votes, record_key)
    }

    #[view]
    /// Return remaining voting power of a stake pool on a proposal.
    /// Note: a stake pool's voting power on a proposal could increase over time(e.g. rewards/new stake).
    public fun get_remaining_voting_power(
        stake_pool: address,
        proposal_id: u64
    ): u64 acquires VotingRecords, VotingRecordsV2 {
        assert_voting_initialization();

        let proposal_expiration = voting::get_proposal_expiration_secs<GovernanceProposal>(
            @cedra_framework,
            proposal_id
        );
        let lockup_until = stake::get_lockup_secs(stake_pool);
        // The voter's stake needs to be locked up at least as long as the proposal's expiration.
        // Also no one can vote on a expired proposal.
        if (proposal_expiration > lockup_until || timestamp::now_seconds() > proposal_expiration) {
            return 0
        };

        // If a stake pool has already voted on a proposal before partial governance voting is enabled, the stake pool
        // cannot vote on the proposal even after partial governance voting is enabled.
        if (has_entirely_voted(stake_pool, proposal_id)) {
            return 0
        };
        let record_key = RecordKey {
            stake_pool,
            proposal_id,
        };
        let used_voting_power = *VotingRecordsV2[@cedra_framework].votes.borrow_with_default(record_key, &0);
        get_voting_power(stake_pool) - used_voting_power
    }

    public fun assert_proposal_expiration(stake_pool: address, proposal_id: u64) {
        assert_voting_initialization();
        let proposal_expiration = voting::get_proposal_expiration_secs<GovernanceProposal>(
            @cedra_framework,
            proposal_id
        );
        // The voter's stake needs to be locked up at least as long as the proposal's expiration.
        assert!(
            proposal_expiration <= stake::get_lockup_secs(stake_pool),
            error::invalid_argument(EINSUFFICIENT_STAKE_LOCKUP),
        );
        assert!(
            timestamp::now_seconds() <= proposal_expiration,
            error::invalid_argument(EPROPOSAL_EXPIRED),
        );
    }

    /// Create a single-step proposal with the backing `stake_pool`.
    /// @param execution_hash Required. This is the hash of the resolution script. When the proposal is resolved,
    /// only the exact script with matching hash can be successfully executed.
    public entry fun create_proposal(
        proposer: &signer,
        stake_pool: address,
        execution_hash: vector<u8>,
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>,
    ) acquires GovernanceConfig, GovernanceEvents {
        create_proposal_v2(proposer, stake_pool, execution_hash, metadata_location, metadata_hash, false);
    }

    /// Create a single-step or multi-step proposal with the backing `stake_pool`.
    /// @param execution_hash Required. This is the hash of the resolution script. When the proposal is resolved,
    /// only the exact script with matching hash can be successfully executed.
    public entry fun create_proposal_v2(
        proposer: &signer,
        stake_pool: address,
        execution_hash: vector<u8>,
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>,
        is_multi_step_proposal: bool,
    ) acquires GovernanceConfig, GovernanceEvents {
        create_proposal_v2_impl(
            proposer,
            stake_pool,
            execution_hash,
            metadata_location,
            metadata_hash,
            is_multi_step_proposal
        );
    }

    /// Create a single-step or multi-step proposal with the backing `stake_pool`.
    /// @param execution_hash Required. This is the hash of the resolution script. When the proposal is resolved,
    /// only the exact script with matching hash can be successfully executed.
    /// Return proposal_id when a proposal is successfully created.
    public fun create_proposal_v2_impl(
        proposer: &signer,
        stake_pool: address,
        execution_hash: vector<u8>,
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>,
        is_multi_step_proposal: bool,
    ): u64 acquires GovernanceConfig, GovernanceEvents {
        check_governance_permission(proposer);
        let proposer_address = signer::address_of(proposer);
        assert!(
            stake::get_delegated_voter(stake_pool) == proposer_address,
            error::invalid_argument(ENOT_DELEGATED_VOTER)
        );

        // The proposer's stake needs to be at least the required bond amount.
        let governance_config = borrow_global<GovernanceConfig>(@cedra_framework);
        let stake_balance = get_voting_power(stake_pool);
        assert!(
            stake_balance >= governance_config.required_proposer_stake,
            error::invalid_argument(EINSUFFICIENT_PROPOSER_STAKE),
        );

        // The proposer's stake needs to be locked up at least as long as the proposal's voting period.
        let current_time = timestamp::now_seconds();
        let proposal_expiration = current_time + governance_config.voting_duration_secs;
        assert!(
            stake::get_lockup_secs(stake_pool) >= proposal_expiration,
            error::invalid_argument(EINSUFFICIENT_STAKE_LOCKUP),
        );

        // Create and validate proposal metadata.
        let proposal_metadata = create_proposal_metadata(metadata_location, metadata_hash);

        // We want to allow early resolution of proposals if more than 50% of the total supply of the network coins
        // has voted. This doesn't take into subsequent inflation/deflation (rewards are issued every epoch and gas fees
        // are burnt after every transaction), but inflation/delation is very unlikely to have a major impact on total
        // supply during the voting period.
        let total_voting_token_supply = coin::supply<CedraCoin>();
        let early_resolution_vote_threshold = option::none<u128>();
        if (option::is_some(&total_voting_token_supply)) {
            let total_supply = *option::borrow(&total_voting_token_supply);
            // 50% + 1 to avoid rounding errors.
            early_resolution_vote_threshold = option::some(total_supply / 2 + 1);
        };

        let proposal_id = voting::create_proposal_v2(
            proposer_address,
            @cedra_framework,
            governance_proposal::create_proposal(),
            execution_hash,
            governance_config.min_voting_threshold,
            proposal_expiration,
            early_resolution_vote_threshold,
            proposal_metadata,
            is_multi_step_proposal,
        );

        if (std::features::module_event_migration_enabled()) {
            event::emit(
                CreateProposal {
                    proposal_id,
                    proposer: proposer_address,
                    stake_pool,
                    execution_hash,
                    proposal_metadata,
                },
            );
        } else {
            let events = borrow_global_mut<GovernanceEvents>(@cedra_framework);
            event::emit_event<CreateProposalEvent>(
                &mut events.create_proposal_events,
                CreateProposalEvent {
                    proposal_id,
                    proposer: proposer_address,
                    stake_pool,
                    execution_hash,
                    proposal_metadata,
                },
            );
        };
        proposal_id
    }

    /// Vote on proposal with proposal_id and all voting power from multiple stake_pools.
    public entry fun batch_vote(
        voter: &signer,
        stake_pools: vector<address>,
        proposal_id: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, VotingRecords, VotingRecordsV2, GovernanceEvents {
        vector::for_each(stake_pools, |stake_pool| {
            vote_internal(voter, stake_pool, proposal_id, MAX_U64, should_pass);
        });
    }

    /// Batch vote on proposal with proposal_id and specified voting power from multiple stake_pools.
    public entry fun batch_partial_vote(
        voter: &signer,
        stake_pools: vector<address>,
        proposal_id: u64,
        voting_power: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, VotingRecords, VotingRecordsV2, GovernanceEvents {
        vector::for_each(stake_pools, |stake_pool| {
            vote_internal(voter, stake_pool, proposal_id, voting_power, should_pass);
        });
    }

    /// Vote on proposal with `proposal_id` and all voting power from `stake_pool`.
    public entry fun vote(
        voter: &signer,
        stake_pool: address,
        proposal_id: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, VotingRecords, VotingRecordsV2, GovernanceEvents {
        vote_internal(voter, stake_pool, proposal_id, MAX_U64, should_pass);
    }

    /// Vote on proposal with `proposal_id` and specified voting power from `stake_pool`.
    public entry fun partial_vote(
        voter: &signer,
        stake_pool: address,
        proposal_id: u64,
        voting_power: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, VotingRecords, VotingRecordsV2, GovernanceEvents {
        vote_internal(voter, stake_pool, proposal_id, voting_power, should_pass);
    }

    /// Vote on proposal with `proposal_id` and specified voting_power from `stake_pool`.
    /// If voting_power is more than all the left voting power of `stake_pool`, use all the left voting power.
    /// If a stake pool has already voted on a proposal before partial governance voting is enabled, the stake pool
    /// cannot vote on the proposal even after partial governance voting is enabled.
    fun vote_internal(
        voter: &signer,
        stake_pool: address,
        proposal_id: u64,
        voting_power: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, VotingRecords, VotingRecordsV2, GovernanceEvents {
        permissioned_signer::assert_master_signer(voter);
        let voter_address = signer::address_of(voter);
        assert!(stake::get_delegated_voter(stake_pool) == voter_address, error::invalid_argument(ENOT_DELEGATED_VOTER));

        assert_proposal_expiration(stake_pool, proposal_id);

        // If a stake pool has already voted on a proposal before partial governance voting is enabled,
        // `get_remaining_voting_power` returns 0.
        let staking_pool_voting_power = get_remaining_voting_power(stake_pool, proposal_id);
        voting_power = min(voting_power, staking_pool_voting_power);

        // Short-circuit if the voter has no voting power.
        assert!(voting_power > 0, error::invalid_argument(ENO_VOTING_POWER));

        voting::vote<GovernanceProposal>(
            &governance_proposal::create_empty_proposal(),
            @cedra_framework,
            proposal_id,
            voting_power,
            should_pass,
        );

        let record_key = RecordKey {
            stake_pool,
            proposal_id,
        };
        let used_voting_power = VotingRecordsV2[@cedra_framework].votes.borrow_mut_with_default(record_key, 0);
        // This calculation should never overflow because the used voting cannot exceed the total voting power of this stake pool.
        *used_voting_power += voting_power;

        if (std::features::module_event_migration_enabled()) {
            event::emit(
                Vote {
                    proposal_id,
                    voter: voter_address,
                    stake_pool,
                    num_votes: voting_power,
                    should_pass,
                },
            );
        } else {
            let events = &mut GovernanceEvents[@cedra_framework];
            event::emit_event(
                &mut events.vote_events,
                VoteEvent {
                    proposal_id,
                    voter: voter_address,
                    stake_pool,
                    num_votes: voting_power,
                    should_pass,
                },
            );
        };

        let proposal_state = voting::get_proposal_state<GovernanceProposal>(@cedra_framework, proposal_id);
        if (proposal_state == PROPOSAL_STATE_SUCCEEDED) {
            add_approved_script_hash(proposal_id);
        }
    }

    public entry fun add_approved_script_hash_script(proposal_id: u64) acquires ApprovedExecutionHashes {
        add_approved_script_hash(proposal_id)
    }

    /// Add the execution script hash of a successful governance proposal to the approved list.
    /// This is needed to bypass the mempool transaction size limit for approved governance proposal transactions that
    /// are too large (e.g. module upgrades).
    public fun add_approved_script_hash(proposal_id: u64) acquires ApprovedExecutionHashes {
        let approved_hashes = borrow_global_mut<ApprovedExecutionHashes>(@cedra_framework);

        // Ensure the proposal can be resolved.
        let proposal_state = voting::get_proposal_state<GovernanceProposal>(@cedra_framework, proposal_id);
        assert!(proposal_state == PROPOSAL_STATE_SUCCEEDED, error::invalid_argument(EPROPOSAL_NOT_RESOLVABLE_YET));

        let execution_hash = voting::get_execution_hash<GovernanceProposal>(@cedra_framework, proposal_id);

        // If this is a multi-step proposal, the proposal id will already exist in the ApprovedExecutionHashes map.
        // We will update execution hash in ApprovedExecutionHashes to be the next_execution_hash.
        if (simple_map::contains_key(&approved_hashes.hashes, &proposal_id)) {
            let current_execution_hash = simple_map::borrow_mut(&mut approved_hashes.hashes, &proposal_id);
            *current_execution_hash = execution_hash;
        } else {
            simple_map::add(&mut approved_hashes.hashes, proposal_id, execution_hash);
        }
    }

    /// Resolve a successful single-step proposal. This would fail if the proposal is not successful (not enough votes or more no
    /// than yes).
    public fun resolve(
        proposal_id: u64,
        signer_address: address
    ): signer acquires ApprovedExecutionHashes, GovernanceResponsbility {
        voting::resolve<GovernanceProposal>(@cedra_framework, proposal_id);
        remove_approved_hash(proposal_id);
        get_signer(signer_address)
    }

    /// Resolve a successful multi-step proposal. This would fail if the proposal is not successful.
    public fun resolve_multi_step_proposal(
        proposal_id: u64,
        signer_address: address,
        next_execution_hash: vector<u8>
    ): signer acquires GovernanceResponsbility, ApprovedExecutionHashes {
        voting::resolve_proposal_v2<GovernanceProposal>(@cedra_framework, proposal_id, next_execution_hash);
        // If the current step is the last step of this multi-step proposal,
        // we will remove the execution hash from the ApprovedExecutionHashes map.
        if (vector::length(&next_execution_hash) == 0) {
            remove_approved_hash(proposal_id);
        } else {
            // If the current step is not the last step of this proposal,
            // we replace the current execution hash with the next execution hash
            // in the ApprovedExecutionHashes map.
            add_approved_script_hash(proposal_id)
        };
        get_signer(signer_address)
    }

    /// Remove an approved proposal's execution script hash.
    public fun remove_approved_hash(proposal_id: u64) acquires ApprovedExecutionHashes {
        assert!(
            voting::is_resolved<GovernanceProposal>(@cedra_framework, proposal_id),
            error::invalid_argument(EPROPOSAL_NOT_RESOLVED_YET),
        );

        let approved_hashes = &mut borrow_global_mut<ApprovedExecutionHashes>(@cedra_framework).hashes;
        if (simple_map::contains_key(approved_hashes, &proposal_id)) {
            simple_map::remove(approved_hashes, &proposal_id);
        };
    }

    /// Manually reconfigure. Called at the end of a governance txn that alters on-chain configs.
    ///
    /// WARNING: this function always ensures a reconfiguration starts, but when the reconfiguration finishes depends.
    /// - If feature `RECONFIGURE_WITH_DKG` is disabled, it finishes immediately.
    ///   - At the end of the calling transaction, we will be in a new epoch.
    /// - If feature `RECONFIGURE_WITH_DKG` is enabled, it starts DKG, and the new epoch will start in a block prologue after DKG finishes.
    ///
    /// This behavior affects when an update of an on-chain config (e.g. `ConsensusConfig`, `Features`) takes effect,
    /// since such updates are applied whenever we enter an new epoch.
    public entry fun reconfigure(cedra_framework: &signer) {
        system_addresses::assert_cedra_framework(cedra_framework);
        if (consensus_config::validator_txn_enabled() && randomness_config::enabled()) {
            reconfiguration_with_dkg::try_start();
        } else {
            reconfiguration_with_dkg::finish(cedra_framework);
        }
    }

    /// Change epoch immediately.
    /// If `RECONFIGURE_WITH_DKG` is enabled and we are in the middle of a DKG,
    /// stop waiting for DKG and enter the new epoch without randomness.
    ///
    /// WARNING: currently only used by tests. In most cases you should use `reconfigure()` instead.
    /// TODO: migrate these tests to be aware of async reconfiguration.
    public entry fun force_end_epoch(cedra_framework: &signer) {
        system_addresses::assert_cedra_framework(cedra_framework);
        reconfiguration_with_dkg::finish(cedra_framework);
    }

    /// `force_end_epoch()` equivalent but only called in testnet,
    /// where the core resources account exists and has been granted power to mint Cedra coins.
    public entry fun force_end_epoch_test_only(cedra_framework: &signer) acquires GovernanceResponsbility {
        let core_signer = get_signer_testnet_only(cedra_framework, @0x1);
        system_addresses::assert_cedra_framework(&core_signer);
        reconfiguration_with_dkg::finish(&core_signer);
    }

    /// Update feature flags and also trigger reconfiguration.
    public fun toggle_features(cedra_framework: &signer, enable: vector<u64>, disable: vector<u64>) {
        system_addresses::assert_cedra_framework(cedra_framework);
        features::change_feature_flags_for_next_epoch(cedra_framework, enable, disable);
        reconfigure(cedra_framework);
    }

    /// Only called in testnet where the core resources account exists and has been granted power to mint Cedra coins.
    public fun get_signer_testnet_only(
        core_resources: &signer, signer_address: address): signer acquires GovernanceResponsbility {
        system_addresses::assert_core_resource(core_resources);
        // Core resources account only has mint capability in tests/testnets.
        assert!(cedra_coin::has_mint_capability(core_resources), error::unauthenticated(EUNAUTHORIZED));
        get_signer(signer_address)
    }

    #[view]
    /// Return the voting power a stake pool has with respect to governance proposals.
    public fun get_voting_power(pool_address: address): u64 {
        let allow_validator_set_change = staking_config::get_allow_validator_set_change(&staking_config::get());
        if (allow_validator_set_change) {
            let (active, _, pending_active, pending_inactive) = stake::get_stake(pool_address);
            // We calculate the voting power as total non-inactive stakes of the pool. Even if the validator is not in the
            // active validator set, as long as they have a lockup (separately checked in create_proposal and voting), their
            // stake would still count in their voting power for governance proposals.
            active + pending_active + pending_inactive
        } else {
            stake::get_current_epoch_voting_power(pool_address)
        }
    }

    /// Return a signer for making changes to 0x1 as part of on-chain governance proposal process.
    fun get_signer(signer_address: address): signer acquires GovernanceResponsbility {
        let governance_responsibility = borrow_global<GovernanceResponsbility>(@cedra_framework);
        let signer_cap = simple_map::borrow(&governance_responsibility.signer_caps, &signer_address);
        create_signer_with_capability(signer_cap)
    }

    fun create_proposal_metadata(
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>
    ): SimpleMap<String, vector<u8>> {
        assert!(string::length(&utf8(metadata_location)) <= 256, error::invalid_argument(EMETADATA_LOCATION_TOO_LONG));
        assert!(string::length(&utf8(metadata_hash)) <= 256, error::invalid_argument(EMETADATA_HASH_TOO_LONG));

        let metadata = simple_map::create<String, vector<u8>>();
        simple_map::add(&mut metadata, utf8(METADATA_LOCATION_KEY), metadata_location);
        simple_map::add(&mut metadata, utf8(METADATA_HASH_KEY), metadata_hash);
        metadata
    }

    fun assert_voting_initialization() {
        assert!(exists<VotingRecordsV2>(@cedra_framework), error::invalid_state(EPARTIAL_VOTING_NOT_INITIALIZED));
    }

    #[test_only]
    public entry fun create_proposal_for_test(
        proposer: &signer,
        multi_step: bool,
    ) acquires GovernanceConfig, GovernanceEvents {
        let execution_hash = vector[1];
        if (multi_step) {
            create_proposal_v2(
                proposer,
                signer::address_of(proposer),
                execution_hash,
                b"",
                b"",
                true,
            );
        } else {
            create_proposal(
                proposer,
                signer::address_of(proposer),
                execution_hash,
                b"",
                b"",
            );
        };
    }

    #[test_only]
    public fun resolve_proposal_for_test(
        proposal_id: u64,
        signer_address: address,
        multi_step: bool,
        finish_multi_step_execution: bool
    ): signer acquires ApprovedExecutionHashes, GovernanceResponsbility {
        if (multi_step) {
            let execution_hash = vector::empty<u8>();
            vector::push_back(&mut execution_hash, 1);

            if (finish_multi_step_execution) {
                resolve_multi_step_proposal(proposal_id, signer_address, vector::empty<u8>())
            } else {
                resolve_multi_step_proposal(proposal_id, signer_address, execution_hash)
            }
        } else {
            resolve(proposal_id, signer_address)
        }
    }

    #[test_only]
    /// Force reconfigure. To be called at the end of a proposal that alters on-chain configs.
    public fun toggle_features_for_test(enable: vector<u64>, disable: vector<u64>) {
        toggle_features(&account::create_signer_for_test(@0x1), enable, disable);
    }

    #[test_only]
    public entry fun test_voting_generic(
        cedra_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
        multi_step: bool,
        use_generic_resolve_function: bool,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        setup_partial_voting(&cedra_framework, &proposer, &yes_voter, &no_voter);

        let execution_hash = vector[1];

        create_proposal_for_test(&proposer, multi_step);

        vote(&yes_voter, signer::address_of(&yes_voter), 0, true);
        vote(&no_voter, signer::address_of(&no_voter), 0, false);

        test_resolving_proposal_generic(cedra_framework, use_generic_resolve_function, execution_hash);
    }

    #[test_only]
    public entry fun test_resolving_proposal_generic(
        cedra_framework: signer,
        use_generic_resolve_function: bool,
        execution_hash: vector<u8>,
    ) acquires ApprovedExecutionHashes, GovernanceResponsbility {
        // Once expiration time has passed, the proposal should be considered resolve now as there are more yes votes
        // than no.
        timestamp::update_global_time_for_test(100001000000);
        let proposal_state = voting::get_proposal_state<GovernanceProposal>(signer::address_of(&cedra_framework), 0);
        assert!(proposal_state == PROPOSAL_STATE_SUCCEEDED, proposal_state);

        // Add approved script hash.
        add_approved_script_hash(0);
        let approved_hashes = borrow_global<ApprovedExecutionHashes>(@cedra_framework).hashes;
        assert!(*simple_map::borrow(&approved_hashes, &0) == execution_hash, 0);

        // Resolve the proposal.
        let account = resolve_proposal_for_test(0, @cedra_framework, use_generic_resolve_function, true);
        assert!(signer::address_of(&account) == @cedra_framework, 1);
        assert!(voting::is_resolved<GovernanceProposal>(@cedra_framework, 0), 2);
        let approved_hashes = borrow_global<ApprovedExecutionHashes>(@cedra_framework).hashes;
        assert!(!simple_map::contains_key(&approved_hashes, &0), 3);
    }

    #[test(cedra_framework = @cedra_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_voting(
        cedra_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        test_voting_generic(cedra_framework, proposer, yes_voter, no_voter, false, false);
    }

    #[test(cedra_framework = @cedra_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_voting_multi_step(
        cedra_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        test_voting_generic(cedra_framework, proposer, yes_voter, no_voter, true, true);
    }

    #[test(cedra_framework = @cedra_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    #[expected_failure(abort_code = 0x5000a, location = cedra_framework::voting)]
    public entry fun test_voting_multi_step_cannot_use_single_step_resolve(
        cedra_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        test_voting_generic(cedra_framework, proposer, yes_voter, no_voter, true, false);
    }

    #[test(cedra_framework = @cedra_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_voting_single_step_can_use_generic_resolve_function(
        cedra_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        test_voting_generic(cedra_framework, proposer, yes_voter, no_voter, false, true);
    }

    #[test_only]
    public entry fun test_can_remove_approved_hash_if_executed_directly_via_voting_generic(
        cedra_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
        multi_step: bool,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        setup_partial_voting(&cedra_framework, &proposer, &yes_voter, &no_voter);

        create_proposal_for_test(&proposer, multi_step);
        vote(&yes_voter, signer::address_of(&yes_voter), 0, true);
        vote(&no_voter, signer::address_of(&no_voter), 0, false);

        // Add approved script hash.
        timestamp::update_global_time_for_test(100001000000);
        add_approved_script_hash(0);

        // Resolve the proposal.
        if (multi_step) {
            let execution_hash = vector::empty<u8>();
            let next_execution_hash = vector::empty<u8>();
            vector::push_back(&mut execution_hash, 1);
            voting::resolve_proposal_v2<GovernanceProposal>(@cedra_framework, 0, next_execution_hash);
            assert!(voting::is_resolved<GovernanceProposal>(@cedra_framework, 0), 0);
            if (vector::length(&next_execution_hash) == 0) {
                remove_approved_hash(0);
            } else {
                add_approved_script_hash(0)
            };
        } else {
            voting::resolve<GovernanceProposal>(@cedra_framework, 0);
            assert!(voting::is_resolved<GovernanceProposal>(@cedra_framework, 0), 0);
            remove_approved_hash(0);
        };
        let approved_hashes = borrow_global<ApprovedExecutionHashes>(@cedra_framework).hashes;
        assert!(!simple_map::contains_key(&approved_hashes, &0), 1);
    }

    #[test(cedra_framework = @cedra_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_can_remove_approved_hash_if_executed_directly_via_voting(
        cedra_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        test_can_remove_approved_hash_if_executed_directly_via_voting_generic(
            cedra_framework,
            proposer,
            yes_voter,
            no_voter,
            false
        );
    }

    #[test(cedra_framework = @cedra_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_can_remove_approved_hash_if_executed_directly_via_voting_multi_step(
        cedra_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        test_can_remove_approved_hash_if_executed_directly_via_voting_generic(
            cedra_framework,
            proposer,
            yes_voter,
            no_voter,
            true
        );
    }

    #[test(cedra_framework = @cedra_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    #[expected_failure(abort_code = 65541, location = cedra_framework::cedra_governance)]
    public entry fun test_cannot_double_vote(
        cedra_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        setup_voting(&cedra_framework, &proposer, &voter_1, &voter_2);

        create_proposal(
            &proposer,
            signer::address_of(&proposer),
            b"0",
            b"",
            b"",
        );

        // Double voting should throw an error.
        vote(&voter_1, signer::address_of(&voter_1), 0, true);
        vote(&voter_1, signer::address_of(&voter_1), 0, true);
    }

    #[test(cedra_framework = @cedra_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    #[expected_failure(abort_code = 65551, location = cedra_framework::cedra_governance)]
    public entry fun test_cannot_vote_for_expired_proposal(
        cedra_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        setup_partial_voting_with_initialized_stake(&cedra_framework, &proposer, &voter_1, &voter_2);

        create_proposal(
            &proposer,
            signer::address_of(&proposer),
            b"0",
            b"",
            b"",
        );

        timestamp::fast_forward_seconds(2000);
        stake::end_epoch();

        // Should abort because the proposal has expired.
        vote(&voter_1, signer::address_of(&voter_1), 0, true);
    }

    #[test(cedra_framework = @cedra_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @0x345)]
    #[expected_failure(abort_code = 65539, location = cedra_framework::cedra_governance)]
    public entry fun test_cannot_vote_due_to_insufficient_stake_lockup(
        cedra_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        setup_partial_voting_with_initialized_stake(&cedra_framework, &proposer, &voter_1, &voter_2);

        create_proposal(
            &proposer,
            signer::address_of(&proposer),
            b"0",
            b"",
            b"",
        );

        // Should abort due to insufficient stake lockup.
        vote(&voter_1, signer::address_of(&voter_1), 0, true);
    }

    #[test(cedra_framework = @cedra_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    #[expected_failure(abort_code = 65541, location = cedra_framework::cedra_governance)]
    public entry fun test_cannot_double_vote_with_different_voter_addresses(
        cedra_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        setup_voting(&cedra_framework, &proposer, &voter_1, &voter_2);

        create_proposal(
            &proposer,
            signer::address_of(&proposer),
            b"0",
            b"",
            b"",
        );

        // Double voting should throw an error for 2 different voters if they still use the same stake pool.
        vote(&voter_1, signer::address_of(&voter_1), 0, true);
        stake::set_delegated_voter(&voter_1, signer::address_of(&voter_2));
        vote(&voter_2, signer::address_of(&voter_1), 0, true);
    }

    #[test(cedra_framework = @cedra_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    public entry fun test_stake_pool_can_vote_on_partial_voting_proposal_many_times(
        cedra_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        setup_partial_voting(&cedra_framework, &proposer, &voter_1, &voter_2);
        let execution_hash = vector[1];
        let proposer_addr = signer::address_of(&proposer);
        let voter_1_addr = signer::address_of(&voter_1);
        let voter_2_addr = signer::address_of(&voter_2);

        create_proposal_for_test(&proposer, true);

        partial_vote(&voter_1, voter_1_addr, 0, 5, true);
        partial_vote(&voter_1, voter_1_addr, 0, 3, true);
        partial_vote(&voter_1, voter_1_addr, 0, 2, true);

        assert!(get_remaining_voting_power(proposer_addr, 0) == 100, 0);
        assert!(get_remaining_voting_power(voter_1_addr, 0) == 10, 1);
        assert!(get_remaining_voting_power(voter_2_addr, 0) == 10, 2);

        test_resolving_proposal_generic(cedra_framework, true, execution_hash);
    }

    #[test(cedra_framework = @cedra_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    #[expected_failure(abort_code = 0x3, location = Self)]
    public entry fun test_stake_pool_can_vote_with_partial_voting_power(
        cedra_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        setup_partial_voting(&cedra_framework, &proposer, &voter_1, &voter_2);
        let execution_hash = vector[1];
        let proposer_addr = signer::address_of(&proposer);
        let voter_1_addr = signer::address_of(&voter_1);
        let voter_2_addr = signer::address_of(&voter_2);

        create_proposal_for_test(&proposer, true);

        partial_vote(&voter_1, voter_1_addr, 0, 9, true);

        assert!(get_remaining_voting_power(proposer_addr, 0) == 100, 0);
        assert!(get_remaining_voting_power(voter_1_addr, 0) == 11, 1);
        assert!(get_remaining_voting_power(voter_2_addr, 0) == 10, 2);

        // No enough Yes. The proposal cannot be resolved.
        test_resolving_proposal_generic(cedra_framework, true, execution_hash);
    }

    #[test(cedra_framework = @cedra_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    public entry fun test_batch_vote(
        cedra_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        features::change_feature_flags_for_testing(&cedra_framework, vector[features::get_coin_to_fungible_asset_migration_feature()], vector[]);
        setup_partial_voting(&cedra_framework, &proposer, &voter_1, &voter_2);
        let execution_hash = vector[1];
        let voter_1_addr = signer::address_of(&voter_1);
        let voter_2_addr = signer::address_of(&voter_2);
        stake::set_delegated_voter(&voter_2, voter_1_addr);
        create_proposal_for_test(&proposer, true);
        batch_vote(&voter_1, vector[voter_1_addr, voter_2_addr], 0, true);
        test_resolving_proposal_generic(cedra_framework, true, execution_hash);
    }

    #[test(cedra_framework = @cedra_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    public entry fun test_batch_partial_vote(
        cedra_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        features::change_feature_flags_for_testing(&cedra_framework, vector[features::get_coin_to_fungible_asset_migration_feature()], vector[]);
        setup_partial_voting(&cedra_framework, &proposer, &voter_1, &voter_2);
        let execution_hash = vector[1];
        let voter_1_addr = signer::address_of(&voter_1);
        let voter_2_addr = signer::address_of(&voter_2);
        stake::set_delegated_voter(&voter_2, voter_1_addr);
        create_proposal_for_test(&proposer, true);
        batch_partial_vote(&voter_1, vector[voter_1_addr, voter_2_addr], 0, 9, true);
        test_resolving_proposal_generic(cedra_framework, true, execution_hash);
    }

    #[test(cedra_framework = @cedra_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    public entry fun test_stake_pool_can_vote_only_with_its_own_voting_power(
        cedra_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        setup_partial_voting(&cedra_framework, &proposer, &voter_1, &voter_2);
        let execution_hash = vector[1];
        let proposer_addr = signer::address_of(&proposer);
        let voter_1_addr = signer::address_of(&voter_1);
        let voter_2_addr = signer::address_of(&voter_2);

        create_proposal_for_test(&proposer, true);

        partial_vote(&voter_1, voter_1_addr, 0, 9, true);
        // The total voting power of voter_1 is 20. It can only vote with 20 voting power even we pass 30 as the argument.
        partial_vote(&voter_1, voter_1_addr, 0, 30, true);

        assert!(get_remaining_voting_power(proposer_addr, 0) == 100, 0);
        assert!(get_remaining_voting_power(voter_1_addr, 0) == 0, 1);
        assert!(get_remaining_voting_power(voter_2_addr, 0) == 10, 2);

        test_resolving_proposal_generic(cedra_framework, true, execution_hash);
    }

    #[test(cedra_framework = @cedra_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    public entry fun test_no_remaining_voting_power_about_proposal_expiration_time(
        cedra_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2, GovernanceEvents {
        setup_partial_voting_with_initialized_stake(&cedra_framework, &proposer, &voter_1, &voter_2);
        let proposer_addr = signer::address_of(&proposer);
        let voter_1_addr = signer::address_of(&voter_1);
        let voter_2_addr = signer::address_of(&voter_2);

        create_proposal_for_test(&proposer, true);
        assert!(get_remaining_voting_power(proposer_addr, 0) == 100, 0);
        assert!(get_remaining_voting_power(voter_1_addr, 0) == 0, 1);
        assert!(get_remaining_voting_power(voter_2_addr, 0) == 0, 2);

        // 500 seconds later, lockup period of voter_1 and voter_2 is reset.
        timestamp::fast_forward_seconds(440);
        stake::end_epoch();
        assert!(get_remaining_voting_power(proposer_addr, 0) == 100, 0);
        assert!(get_remaining_voting_power(voter_1_addr, 0) == 20, 1);
        assert!(get_remaining_voting_power(voter_2_addr, 0) == 10, 2);

        // 501 seconds later, the proposal expires.
        timestamp::fast_forward_seconds(441);
        stake::end_epoch();
        assert!(get_remaining_voting_power(proposer_addr, 0) == 0, 0);
        assert!(get_remaining_voting_power(voter_1_addr, 0) == 0, 1);
        assert!(get_remaining_voting_power(voter_2_addr, 0) == 0, 2);
    }

    #[test_only]
    public fun setup_voting(
        cedra_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires GovernanceResponsbility {
        use std::vector;
        use cedra_framework::account;
        use cedra_framework::coin;
        use cedra_framework::cedra_coin::{Self, CedraCoin};

        timestamp::set_time_has_started_for_testing(cedra_framework);
        account::create_account_for_test(signer::address_of(cedra_framework));
        account::create_account_for_test(signer::address_of(proposer));
        account::create_account_for_test(signer::address_of(yes_voter));
        account::create_account_for_test(signer::address_of(no_voter));

        // Initialize the governance.
        staking_config::initialize_for_test(cedra_framework, 0, 1000, 2000, true, 0, 1, 100);
        initialize(cedra_framework, 10, 100, 1000);
        store_signer_cap(
            cedra_framework,
            @cedra_framework,
            account::create_test_signer_cap(@cedra_framework),
        );

        // Initialize the stake pools for proposer and voters.
        let active_validators = vector::empty<address>();
        vector::push_back(&mut active_validators, signer::address_of(proposer));
        vector::push_back(&mut active_validators, signer::address_of(yes_voter));
        vector::push_back(&mut active_validators, signer::address_of(no_voter));
        let (_sk_1, pk_1, _pop_1) = stake::generate_identity();
        let (_sk_2, pk_2, _pop_2) = stake::generate_identity();
        let (_sk_3, pk_3, _pop_3) = stake::generate_identity();
        let pks = vector[pk_1, pk_2, pk_3];
        stake::create_validator_set(cedra_framework, active_validators, pks);

        let (burn_cap, mint_cap) = cedra_coin::initialize_for_test(cedra_framework);
        // Spread stake among active and pending_inactive because both need to be accounted for when computing voting
        // power.
        coin::register<CedraCoin>(proposer);
        coin::deposit(signer::address_of(proposer), coin::mint(100, &mint_cap));
        coin::register<CedraCoin>(yes_voter);
        coin::deposit(signer::address_of(yes_voter), coin::mint(20, &mint_cap));
        coin::register<CedraCoin>(no_voter);
        coin::deposit(signer::address_of(no_voter), coin::mint(10, &mint_cap));
        stake::create_stake_pool(proposer, coin::mint(50, &mint_cap), coin::mint(50, &mint_cap), 10000);
        stake::create_stake_pool(yes_voter, coin::mint(10, &mint_cap), coin::mint(10, &mint_cap), 10000);
        stake::create_stake_pool(no_voter, coin::mint(5, &mint_cap), coin::mint(5, &mint_cap), 10000);
        coin::destroy_mint_cap<CedraCoin>(mint_cap);
        coin::destroy_burn_cap<CedraCoin>(burn_cap);
    }

    #[test_only]
    public fun setup_voting_with_initialized_stake(
        cedra_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires GovernanceResponsbility {
        use cedra_framework::account;
        use cedra_framework::coin;
        use cedra_framework::cedra_coin::CedraCoin;

        timestamp::set_time_has_started_for_testing(cedra_framework);
        account::create_account_for_test(signer::address_of(cedra_framework));
        account::create_account_for_test(signer::address_of(proposer));
        account::create_account_for_test(signer::address_of(yes_voter));
        account::create_account_for_test(signer::address_of(no_voter));

        // Initialize the governance.
        stake::initialize_for_test_custom(cedra_framework, 0, 1000, 2000, true, 0, 1, 1000);
        initialize(cedra_framework, 10, 100, 1000);
        store_signer_cap(
            cedra_framework,
            @cedra_framework,
            account::create_test_signer_cap(@cedra_framework),
        );

        // Initialize the stake pools for proposer and voters.
        // Spread stake among active and pending_inactive because both need to be accounted for when computing voting
        // power.
        coin::register<CedraCoin>(proposer);
        coin::deposit(signer::address_of(proposer), stake::mint_coins(100));
        coin::register<CedraCoin>(yes_voter);
        coin::deposit(signer::address_of(yes_voter), stake::mint_coins(20));
        coin::register<CedraCoin>(no_voter);
        coin::deposit(signer::address_of(no_voter), stake::mint_coins(10));

        let (_sk_1, pk_1, pop_1) = stake::generate_identity();
        let (_sk_2, pk_2, pop_2) = stake::generate_identity();
        let (_sk_3, pk_3, pop_3) = stake::generate_identity();
        stake::initialize_test_validator(&pk_2, &pop_2, yes_voter, 20, true, false);
        stake::initialize_test_validator(&pk_3, &pop_3, no_voter, 10, true, false);
        stake::end_epoch();
        timestamp::fast_forward_seconds(1440);
        stake::initialize_test_validator(&pk_1, &pop_1, proposer, 100, true, false);
        stake::end_epoch();
    }

    #[test_only]
    public fun setup_partial_voting_with_initialized_stake(
        cedra_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires GovernanceResponsbility {
        setup_voting_with_initialized_stake(cedra_framework, proposer, yes_voter, no_voter);
    }

    #[test_only]
    public fun setup_partial_voting(
        cedra_framework: &signer,
        proposer: &signer,
        voter_1: &signer,
        voter_2: &signer,
    ) acquires GovernanceResponsbility {
        setup_voting(cedra_framework, proposer, voter_1, voter_2);
    }

    #[test(cedra_framework = @cedra_framework)]
    public entry fun test_update_governance_config(
        cedra_framework: signer,
    ) acquires GovernanceConfig, GovernanceEvents {
        account::create_account_for_test(signer::address_of(&cedra_framework));
        initialize(&cedra_framework, 1, 2, 3);
        update_governance_config(&cedra_framework, 10, 20, 30);

        let config = borrow_global<GovernanceConfig>(@cedra_framework);
        assert!(config.min_voting_threshold == 10, 0);
        assert!(config.required_proposer_stake == 20, 1);
        assert!(config.voting_duration_secs == 30, 3);
    }

    #[test(account = @0x123)]
    #[expected_failure(abort_code = 0x50003, location = cedra_framework::system_addresses)]
    public entry fun test_update_governance_config_unauthorized_should_fail(
        account: signer) acquires GovernanceConfig, GovernanceEvents {
        initialize(&account, 1, 2, 3);
        update_governance_config(&account, 10, 20, 30);
    }

    #[test(cedra_framework = @cedra_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_replace_execution_hash(
        cedra_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires GovernanceResponsbility, GovernanceConfig, ApprovedExecutionHashes, VotingRecords, VotingRecordsV2, GovernanceEvents {
        setup_partial_voting(&cedra_framework, &proposer, &yes_voter, &no_voter);

        create_proposal_for_test(&proposer, true);
        vote(&yes_voter, signer::address_of(&yes_voter), 0, true);
        vote(&no_voter, signer::address_of(&no_voter), 0, false);

        // Add approved script hash.
        timestamp::update_global_time_for_test(100001000000);
        add_approved_script_hash(0);

        // Resolve the proposal.
        let execution_hash = vector::empty<u8>();
        let next_execution_hash = vector::empty<u8>();
        vector::push_back(&mut execution_hash, 1);
        vector::push_back(&mut next_execution_hash, 10);

        voting::resolve_proposal_v2<GovernanceProposal>(@cedra_framework, 0, next_execution_hash);

        if (vector::length(&next_execution_hash) == 0) {
            remove_approved_hash(0);
        } else {
            add_approved_script_hash(0)
        };

        let approved_hashes = borrow_global<ApprovedExecutionHashes>(@cedra_framework).hashes;
        assert!(*simple_map::borrow(&approved_hashes, &0) == vector[10u8, ], 1);
    }

    #[test_only]
    public fun initialize_for_test(
        cedra_framework: &signer,
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    ) {
        initialize(cedra_framework, min_voting_threshold, required_proposer_stake, voting_duration_secs);
    }

    #[verify_only]
    public fun initialize_for_verification(
        cedra_framework: &signer,
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    ) {
        initialize(cedra_framework, min_voting_threshold, required_proposer_stake, voting_duration_secs);
    }
}
