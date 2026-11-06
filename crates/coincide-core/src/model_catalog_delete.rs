//! Native archive deletion revokes only proofs attached to the reviewed threads.
//! Actual catalog workers remain retained by their ordinary ownership ledger.
use super::*;
impl ModelCatalog {
    pub(crate) fn invalidate_deleted_threads(&mut self, ids: &[String]) {
        let selected = ids
            .iter()
            .map(|id| id.to_ascii_lowercase())
            .collect::<HashSet<_>>();
        for job in self.jobs.values_mut() {
            let thread = job
                .named
                .as_ref()
                .map(NamedBinding::thread)
                .or_else(|| job.response["threadId"].as_str());
            if thread.is_some_and(|thread| selected.contains(&thread.to_ascii_lowercase())) {
                job.cancelled.store(true, Ordering::Release);
                job.response["state"] = json!("cancelled");
                job.response["models"] = json!([]);
            }
        }
        // Limits do not grant execution; discard the current read cache so the
        // next selected thread must establish its own scope after deletion.
        self.named_limits.context(None);
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_delete_revokes_only_matching_thread_scoped_catalog_jobs() {
        let target = uuid::Uuid::new_v4().to_string();
        let other = uuid::Uuid::new_v4().to_string();
        let mut catalog = ModelCatalog::default();
        let mut flags = Vec::new();
        for (index, thread) in [&target, &other].into_iter().enumerate() {
            let flag = Arc::new(AtomicBool::new(false));
            flags.push(flag.clone());
            catalog.jobs.insert(index.to_string(),Job{named:None,binding:None,response:json!({"threadId":thread,"provider":"codex","state":"ready","models":[{"id":"synthetic-model"}]}),cancelled:flag});
        }
        catalog.invalidate_deleted_threads(&[target]);
        assert!(flags[0].load(Ordering::Acquire));
        assert!(!flags[1].load(Ordering::Acquire));
        assert_eq!(catalog.jobs["0"].response["models"], json!([]));
        assert_eq!(catalog.jobs["1"].response["state"], "ready");
    }
}
