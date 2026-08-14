// SPDX-License-Identifier: MIT

//! Local cart rules shared by the Android and iPhone buyer shells.
//!
//! The API remains authoritative for persistence. This state object keeps the
//! native clients aligned on quantity limits, availability, and integer-cent
//! arithmetic before a mutation crosses the network boundary.

use crate::models::{CartItem, CatalogVariant};
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// The web buyer cart accepts quantities in the inclusive range `1..=99`.
pub const MAX_CART_QUANTITY: u32 = 99;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CartLine {
    pub product_id: String,
    pub title: String,
    pub price_cents: i64,
    pub quantity: u32,
    pub available_quantity: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_url: Option<String>,
}

impl CartLine {
    pub fn total_cents(&self) -> Result<i64, CartError> {
        self.price_cents
            .checked_mul(i64::from(self.quantity))
            .ok_or(CartError::MoneyOverflow)
    }

    pub fn as_cart_item(&self) -> CartItem {
        CartItem {
            product_id: self.product_id.clone(),
            title: self.title.clone(),
            price_cents: self.price_cents,
            quantity: self.quantity,
            image_url: self.image_url.clone(),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CartState {
    lines: Vec<CartLine>,
}

impl CartState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn lines(&self) -> &[CartLine] {
        &self.lines
    }

    pub fn is_empty(&self) -> bool {
        self.lines.is_empty()
    }

    pub fn len(&self) -> usize {
        self.lines.len()
    }

    /// Add a catalog variant, merging with an existing line for the product.
    ///
    /// The latest catalog snapshot refreshes display metadata and the
    /// availability cap. The mutation is atomic: a rejected quantity or money
    /// overflow leaves the prior state unchanged.
    pub fn add(&mut self, variant: &CatalogVariant, quantity: u32) -> Result<(), CartError> {
        validate_price(variant)?;

        let existing_quantity = self
            .lines
            .iter()
            .find(|line| line.product_id == variant.id)
            .map_or(0, |line| line.quantity);
        let requested = u64::from(existing_quantity) + u64::from(quantity);
        let available = validate_quantity(&variant.id, requested, variant.available_qty)?;

        let next_line = CartLine {
            product_id: variant.id.clone(),
            title: variant.title.clone(),
            price_cents: variant.price_cents,
            quantity: requested as u32,
            available_quantity: available,
            image_url: variant.image_url.clone(),
        };

        let mut next = self.clone();
        if let Some(line) = next
            .lines
            .iter_mut()
            .find(|line| line.product_id == variant.id)
        {
            *line = next_line;
        } else {
            next.lines.push(next_line);
        }
        next.subtotal_cents()?;
        *self = next;
        Ok(())
    }

    /// Change an existing line quantity without treating zero as removal.
    pub fn set_quantity(&mut self, product_id: &str, quantity: u32) -> Result<(), CartError> {
        let line = self
            .lines
            .iter()
            .find(|line| line.product_id == product_id)
            .ok_or_else(|| CartError::UnknownProduct(product_id.to_owned()))?;
        validate_quantity(
            product_id,
            u64::from(quantity),
            i64::from(line.available_quantity),
        )?;

        let mut next = self.clone();
        next.lines
            .iter_mut()
            .find(|line| line.product_id == product_id)
            .expect("line existence was checked above")
            .quantity = quantity;
        next.subtotal_cents()?;
        *self = next;
        Ok(())
    }

    pub fn remove(&mut self, product_id: &str) -> bool {
        let before = self.lines.len();
        self.lines.retain(|line| line.product_id != product_id);
        self.lines.len() != before
    }

    pub fn clear(&mut self) {
        self.lines.clear();
    }

    pub fn line_total_cents(&self, product_id: &str) -> Result<Option<i64>, CartError> {
        self.lines
            .iter()
            .find(|line| line.product_id == product_id)
            .map(CartLine::total_cents)
            .transpose()
    }

    pub fn subtotal_cents(&self) -> Result<i64, CartError> {
        self.lines.iter().try_fold(0_i64, |subtotal, line| {
            subtotal
                .checked_add(line.total_cents()?)
                .ok_or(CartError::MoneyOverflow)
        })
    }

    pub fn to_cart_items(&self) -> Vec<CartItem> {
        self.lines.iter().map(CartLine::as_cart_item).collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CartError {
    #[error("cart quantity must be at least one")]
    InvalidQuantity,
    #[error("cart quantity {requested} exceeds the per-product limit of {max}")]
    QuantityExceedsLimit { requested: u64, max: u32 },
    #[error("product {product_id} has no units ready")]
    Unavailable { product_id: String },
    #[error(
        "cart quantity {requested} for product {product_id} exceeds the {available} units ready"
    )]
    QuantityExceedsAvailability {
        product_id: String,
        requested: u64,
        available: u32,
    },
    #[error("product {product_id} has a negative price in minor units")]
    NegativePrice { product_id: String },
    #[error("product {0} is not in the cart")]
    UnknownProduct(String),
    #[error("cart money arithmetic overflowed integer minor units")]
    MoneyOverflow,
}

fn validate_price(variant: &CatalogVariant) -> Result<(), CartError> {
    if variant.price_cents < 0 {
        return Err(CartError::NegativePrice {
            product_id: variant.id.clone(),
        });
    }
    Ok(())
}

fn validate_quantity(
    product_id: &str,
    requested: u64,
    available_qty: i64,
) -> Result<u32, CartError> {
    if requested == 0 {
        return Err(CartError::InvalidQuantity);
    }
    if requested > u64::from(MAX_CART_QUANTITY) {
        return Err(CartError::QuantityExceedsLimit {
            requested,
            max: MAX_CART_QUANTITY,
        });
    }

    let available = if available_qty <= 0 {
        0
    } else {
        u32::try_from(available_qty)
            .unwrap_or(u32::MAX)
            .min(MAX_CART_QUANTITY)
    };
    if available == 0 {
        return Err(CartError::Unavailable {
            product_id: product_id.to_owned(),
        });
    }
    if requested > u64::from(available) {
        return Err(CartError::QuantityExceedsAvailability {
            product_id: product_id.to_owned(),
            requested,
            available,
        });
    }
    Ok(available)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn variant(id: &str, price_cents: i64, available_qty: i64) -> CatalogVariant {
        CatalogVariant {
            id: id.into(),
            group_id: None,
            title: format!("Product {id}"),
            brand: "SideStage".into(),
            product_type: "Collectible".into(),
            sku: id.into(),
            condition: None,
            handling_days: None,
            price_cents,
            available_qty,
            image_url: None,
            description: None,
        }
    }

    #[test]
    fn add_merges_quantities_and_uses_integer_cent_totals() {
        let mut cart = CartState::new();
        let product = variant("mug/red", 914_137, 3);

        cart.add(&product, 1).unwrap();
        cart.add(&product, 2).unwrap();

        assert_eq!(cart.len(), 1);
        assert_eq!(cart.lines()[0].quantity, 3);
        assert_eq!(cart.line_total_cents("mug/red").unwrap(), Some(2_742_411));
        assert_eq!(cart.subtotal_cents().unwrap(), 2_742_411);
    }

    #[test]
    fn change_and_remove_recalculate_the_order_total() {
        let mut cart = CartState::new();
        cart.add(&variant("mug/red", 2_400, 4), 2).unwrap();
        cart.add(&variant("pin/blue", 1_500, 2), 1).unwrap();
        assert_eq!(cart.subtotal_cents().unwrap(), 6_300);

        cart.set_quantity("mug/red", 1).unwrap();
        assert_eq!(cart.subtotal_cents().unwrap(), 3_900);
        assert!(cart.remove("pin/blue"));
        assert_eq!(cart.subtotal_cents().unwrap(), 2_400);
        assert!(!cart.remove("missing"));
    }

    #[test]
    fn availability_cap_rejects_the_mutation_without_changing_state() {
        let mut cart = CartState::new();
        let product = variant("mug/red", 2_400, 2);
        cart.add(&product, 1).unwrap();

        let error = cart.add(&product, 2).unwrap_err();
        assert_eq!(
            error,
            CartError::QuantityExceedsAvailability {
                product_id: "mug/red".into(),
                requested: 3,
                available: 2,
            }
        );
        assert_eq!(cart.lines()[0].quantity, 1);
        assert_eq!(cart.subtotal_cents().unwrap(), 2_400);
    }

    #[test]
    fn zero_and_the_web_quantity_limit_are_rejected() {
        let mut cart = CartState::new();
        let product = variant("mug/red", 2_400, 500);

        assert_eq!(cart.add(&product, 0), Err(CartError::InvalidQuantity));
        assert_eq!(
            cart.add(&product, 100),
            Err(CartError::QuantityExceedsLimit {
                requested: 100,
                max: MAX_CART_QUANTITY,
            })
        );
        assert!(cart.is_empty());
    }
}
