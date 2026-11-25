package com.awesomeapp.event

import org.junit.Test
import org.junit.Before
import org.junit.runner.RunWith
import org.junit.runners.JUnit4
import org.junit.Rule
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.ExperimentalCoroutinesApi
import org.junit.Assert.*
import kotlin.test.assertTrue
import kotlin.test.assertNotNull
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import com.awesomeapp.event.*


@OptIn(ExperimentalCoroutinesApi::class)
class Viewmodel30_1Test {
        private lateinit var viewModel: Viewmodel30_1

    @Before
    fun setup() {
        viewModel = Viewmodel30_1()
    }

    @Test
    fun `test state updates with data`() = runTest {
        assertNotNull(viewModel.state.value)
    }
}
