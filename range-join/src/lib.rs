//! Toy range joins on differential dataflow, sized against FlowLog's
//! current cross-product-and-filter lowering.

pub mod gallop;
pub mod range_join;
pub mod seek_join;

pub use range_join::range_join;
pub use seek_join::seek_range_join;
pub use seek_join::seek_range_join_both;
