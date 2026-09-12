// Transaction-script path for `cache::set_feed_configs` (spec/06 M.1): entry functions
// cannot take struct arguments, so a script builds the `FeedConfigEntry` values with the
// public constructors and calls the `public fun`. This example configures one feed with one
// permission; a deployment builds whatever batch it needs the same way.
script {
    use std::string::String;
    use data_feeds::cache;

    fun set_one_feed_config(
        admin: &signer,
        cache: address,
        data_id: vector<u8>,
        description: String,
        allowed_sender: address,
        allowed_workflow_owner: vector<u8>,
        allowed_workflow_name: vector<u8>,
    ) {
        let permission = cache::new_workflow_permission(allowed_sender, allowed_workflow_owner, allowed_workflow_name);
        let config = cache::new_feed_config(description, vector[permission]);
        cache::set_feed_configs(admin, cache, vector[cache::new_feed_config_entry(data_id, config)]);
    }
}
