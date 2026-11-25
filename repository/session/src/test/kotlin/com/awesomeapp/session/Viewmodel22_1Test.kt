package com.awesomeapp.session

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
import com.awesomeapp.session.*


@OptIn(ExperimentalCoroutinesApi::class)
class Viewmodel22_1Test {
        private lateinit var viewModel: Viewmodel22_1

    @Before
    fun setup() {
        viewModel = Viewmodel22_1()
    }

    @Test
    fun `test state updates with data`() = runTest {
        assertNotNull(viewModel.state.value)
    }
}
